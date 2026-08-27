use crate::CoreError;
use base64::Engine;
use bytes::Bytes;
use codex_api::{
    ApiError, AuthProvider, Compression, Provider, ReqwestTransport, ResponseEvent,
    ResponsesClient, RetryConfig, TransportError,
};
use codex_client::{
    HttpTransport, Request as ProviderHttpRequest, Response as ProviderHttpResponse, StreamResponse,
};
use codex_protocol::models::{ContentItem, FunctionCallOutputContentItem, ResponseItem};
use codex_protocol::protocol::TokenUsage;
use codex_utils_stream_parser::{
    AssistantTextChunk, AssistantTextStreamParser, ProposedPlanSegment, extract_proposed_plan_text,
    strip_citations,
};
use futures::{StreamExt, channel::mpsc as futures_mpsc};
use http::{HeaderMap, HeaderName, HeaderValue, StatusCode};
use serde::de::Error as _;
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{Value, json};
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::future::Future;
use std::sync::{Arc, mpsc as std_mpsc};
use std::thread::JoinHandle;
use std::time::Duration;
use tokio::sync::oneshot;

const CHATGPT_CODEX_BASE_URL: &str = "https://chatgpt.com/backend-api/codex";
const OFFICIAL_SOURCE_COMMIT: &str = "ffe1de5cec9c0cd02629eb246534e4622da0ff41";
// The official ChatGPT Codex route can take longer than a normal API request
// to allocate a Responses stream, especially on a mobile network or through a
// user-configured proxy. Keep the timeout bounded, but do not turn a slow
// header handshake into a false transport failure.
const PROVIDER_RESPONSE_HEADERS_TIMEOUT: Duration = Duration::from_secs(90);
const NATIVE_PROVIDER_PREPARE_TIMEOUT: Duration = Duration::from_secs(5);
const OFFICIAL_PLAN_MODE_INSTRUCTIONS: &str = include_str!("../vendor/collaboration-mode-plan.md");
const APPLY_PATCH_LARK_GRAMMAR: &str = r#"start: begin_patch hunk+ end_patch
begin_patch: "*** Begin Patch" LF
end_patch: "*** End Patch" LF?

hunk: add_hunk | delete_hunk | update_hunk
add_hunk: "*** Add File: " filename LF add_line+
delete_hunk: "*** Delete File: " filename LF
update_hunk: "*** Update File: " filename LF change_move? change?

filename: /(.+)/
add_line: "+" /(.*)/ LF -> line

change_move: "*** Move to: " filename LF
change: (change_context | change_line)+ eof_line?
change_context: ("@@" | "@@ " /(.+)/) LF
change_line: ("+" | "-" | " ") /(.*)/ LF
eof_line: "*** End of File" LF

%import common.LF
"#;

#[derive(Clone, Deserialize)]
struct OfficialToolSearchSource {
    name: String,
    description: Option<String>,
}

#[derive(Clone, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
enum OfficialDynamicToolSpec {
    Function(OfficialDynamicToolFunctionSpec),
    Namespace(OfficialDynamicToolNamespaceSpec),
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct OfficialDynamicToolFunctionSpec {
    name: String,
    description: String,
    input_schema: Value,
    #[serde(default)]
    defer_loading: bool,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct OfficialDynamicToolNamespaceSpec {
    name: String,
    description: String,
    tools: Vec<OfficialDynamicToolNamespaceTool>,
}

#[derive(Clone, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
enum OfficialDynamicToolNamespaceTool {
    Function(OfficialDynamicToolFunctionSpec),
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LegacyOfficialDynamicToolSpec {
    namespace: Option<String>,
    name: String,
    description: String,
    input_schema: Value,
    defer_loading: Option<bool>,
    expose_to_context: Option<bool>,
}

fn deserialize_dynamic_tools<'de, D>(
    deserializer: D,
) -> Result<Vec<OfficialDynamicToolSpec>, D::Error>
where
    D: Deserializer<'de>,
{
    let values = Vec::<Value>::deserialize(deserializer)?;
    normalize_dynamic_tools(values).map_err(D::Error::custom)
}

fn normalize_dynamic_tools(
    values: Vec<Value>,
) -> Result<Vec<OfficialDynamicToolSpec>, serde_json::Error> {
    let has_legacy_fields = |value: &Value| {
        value.get("namespace").is_some()
            || value.get("exposeToContext").is_some()
            || value.get("type").is_none()
    };
    let has_legacy_format = values.iter().any(|value| {
        has_legacy_fields(value)
            || value
                .get("tools")
                .and_then(Value::as_array)
                .is_some_and(|tools| tools.iter().any(&has_legacy_fields))
    });
    let has_canonical_format = values.iter().any(|value| value.get("type").is_some());
    if has_legacy_format && has_canonical_format {
        return Err(serde_json::Error::custom(
            "dynamic tools must use either canonical or legacy format consistently",
        ));
    }
    if !has_legacy_format {
        return values.into_iter().map(serde_json::from_value).collect();
    }

    let mut normalized = Vec::<OfficialDynamicToolSpec>::with_capacity(values.len());
    let mut namespace_indices = BTreeMap::<String, usize>::new();
    for value in values {
        let tool: LegacyOfficialDynamicToolSpec = serde_json::from_value(value)?;
        let function = OfficialDynamicToolFunctionSpec {
            name: tool.name,
            description: tool.description,
            input_schema: tool.input_schema,
            defer_loading: tool.defer_loading.unwrap_or_else(|| {
                tool.expose_to_context
                    .map(|visible| !visible)
                    .unwrap_or(false)
            }),
        };
        let Some(namespace) = tool.namespace else {
            normalized.push(OfficialDynamicToolSpec::Function(function));
            continue;
        };
        if let Some(index) = namespace_indices.get(&namespace).copied() {
            let OfficialDynamicToolSpec::Namespace(existing) = &mut normalized[index] else {
                unreachable!("namespace index must point to a namespace")
            };
            existing
                .tools
                .push(OfficialDynamicToolNamespaceTool::Function(function));
        } else {
            namespace_indices.insert(namespace.clone(), normalized.len());
            normalized.push(OfficialDynamicToolSpec::Namespace(
                OfficialDynamicToolNamespaceSpec {
                    name: namespace,
                    description: String::new(),
                    tools: vec![OfficialDynamicToolNamespaceTool::Function(function)],
                },
            ));
        }
    }
    Ok(normalized)
}

#[derive(Clone, Deserialize)]
#[serde(tag = "type")]
enum OfficialUserInput {
    #[serde(rename = "text")]
    Text {
        text: String,
        #[serde(default, rename = "text_elements")]
        text_elements: Vec<serde_json::Value>,
    },
    #[serde(rename = "image")]
    Image { detail: Option<String>, url: String },
    #[serde(rename = "localImage")]
    LocalImage {
        detail: Option<String>,
        path: String,
    },
    #[serde(rename = "audio")]
    Audio { url: String },
    #[serde(rename = "localAudio")]
    LocalAudio { path: String },
    #[serde(rename = "skill")]
    Skill { name: String, path: String },
    #[serde(rename = "mention")]
    Mention { name: String, path: String },
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct OfficialResponseRequest {
    request_id: String,
    access_token: String,
    account_id: Option<String>,
    base_url: Option<String>,
    proxy_url: Option<String>,
    model: String,
    reasoning_effort: String,
    instructions: String,
    #[serde(default)]
    collaboration_instructions: Option<String>,
    #[serde(default)]
    output_schema: Option<Value>,
    input: Vec<OfficialUserInput>,
    #[serde(default)]
    workspace_tools: bool,
    #[serde(default)]
    request_user_input_tool: bool,
    #[serde(default)]
    request_permissions_tool: bool,
    #[serde(default)]
    update_plan_tool: bool,
    #[serde(default)]
    view_image_tool: bool,
    #[serde(default)]
    mcp_resource_tools: bool,
    #[serde(default)]
    plan_mode: bool,
    #[serde(default)]
    tool_search_sources: Vec<OfficialToolSearchSource>,
    #[serde(default, deserialize_with = "deserialize_dynamic_tools")]
    dynamic_tools: Vec<OfficialDynamicToolSpec>,
    #[serde(default)]
    prior_input_items: Vec<String>,
    #[serde(default)]
    input_history: Vec<String>,
}

struct BearerAuth {
    token: String,
    account_id: Option<String>,
}

impl AuthProvider for BearerAuth {
    fn add_auth_headers(&self, headers: &mut HeaderMap) {
        if let Ok(value) = HeaderValue::from_str(&format!("Bearer {}", self.token)) {
            headers.insert(http::header::AUTHORIZATION, value);
        }
        if let Some(account_id) = self.account_id.as_deref()
            && let Ok(value) = HeaderValue::from_str(account_id)
        {
            headers.insert("ChatGPT-Account-ID", value);
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ResponseStartedEvent<'a> {
    sequence: u64,
    kind: &'static str,
    request_id: &'a str,
    source_commit: &'static str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct AssistantTextDeltaEvent<'a> {
    sequence: u64,
    kind: &'static str,
    request_id: &'a str,
    delta: &'a str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PlanStartedEvent<'a> {
    sequence: u64,
    kind: &'static str,
    request_id: &'a str,
    item_id: &'a str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PlanDeltaEvent<'a> {
    sequence: u64,
    kind: &'static str,
    request_id: &'a str,
    item_id: &'a str,
    delta: &'a str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PlanCompletedEvent<'a> {
    sequence: u64,
    kind: &'static str,
    request_id: &'a str,
    item_id: &'a str,
    text: &'a str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ResponseCompletedEvent<'a> {
    sequence: u64,
    kind: &'static str,
    request_id: &'a str,
    response_id: &'a str,
    usage: Option<&'a TokenUsageWire>,
    end_turn: Option<bool>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct TokenUsageWire {
    total_tokens: i64,
    input_tokens: i64,
    cached_input_tokens: i64,
    cache_write_input_tokens: i64,
    output_tokens: i64,
    reasoning_output_tokens: i64,
}

impl From<TokenUsage> for TokenUsageWire {
    fn from(usage: TokenUsage) -> Self {
        Self {
            total_tokens: usage.total_tokens,
            input_tokens: usage.input_tokens,
            cached_input_tokens: usage.cached_input_tokens,
            cache_write_input_tokens: usage.cache_write_input_tokens,
            output_tokens: usage.output_tokens,
            reasoning_output_tokens: usage.reasoning_output_tokens,
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ToolCallRequestedEvent<'a> {
    sequence: u64,
    kind: &'static str,
    request_id: &'a str,
    name: &'a str,
    arguments: &'a str,
    call_id: &'a str,
    item_json: &'a str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ResponseItemDoneEvent<'a> {
    sequence: u64,
    kind: &'static str,
    request_id: &'a str,
    item_json: &'a str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ProviderRealtimeEvent<'a> {
    sequence: u64,
    kind: &'static str,
    request_id: &'a str,
    event_type: &'a str,
    payload: &'a serde_json::Value,
}

enum NormalizedEvent {
    Delta(String),
    PlanStarted {
        item_id: String,
    },
    PlanDelta {
        item_id: String,
        delta: String,
    },
    PlanCompleted {
        item_id: String,
        text: String,
    },
    ResponseItem(String),
    ToolCall {
        name: String,
        arguments: String,
        call_id: String,
        item_json: String,
    },
    Realtime {
        event_type: &'static str,
        payload: serde_json::Value,
    },
    Completed {
        response_id: String,
        usage: Option<TokenUsageWire>,
        end_turn: Option<bool>,
    },
}

struct PlanTextNormalizer {
    plan_mode: bool,
    parser: AssistantTextStreamParser,
    item_id: String,
    started: bool,
    completed: bool,
    accumulated_text: String,
    leading_normal_whitespace: String,
    normal_text_started: bool,
}

impl PlanTextNormalizer {
    fn new(request_id: &str, plan_mode: bool) -> Self {
        Self {
            plan_mode,
            parser: AssistantTextStreamParser::new(plan_mode),
            item_id: format!("{request_id}-plan"),
            started: false,
            completed: false,
            accumulated_text: String::new(),
            leading_normal_whitespace: String::new(),
            normal_text_started: false,
        }
    }

    fn push_str(&mut self, delta: &str) -> Vec<NormalizedEvent> {
        if !self.plan_mode {
            return vec![NormalizedEvent::Delta(delta.to_string())];
        }
        let parsed = self.parser.push_str(delta);
        self.normalized_chunk(parsed)
    }

    fn complete_with_response_text(&mut self, response_text: Option<&str>) -> Vec<NormalizedEvent> {
        if !self.plan_mode || self.completed {
            return Vec::new();
        }
        let trailing_chunk = self.parser.finish();
        let mut events = self.normalized_chunk(trailing_chunk);
        let authoritative_text = response_text
            .and_then(extract_proposed_plan_text)
            .map(|text| strip_citations(&text).0);
        if let Some(text) = authoritative_text {
            self.ensure_started(&mut events);
            self.completed = true;
            events.push(NormalizedEvent::PlanCompleted {
                item_id: self.item_id.clone(),
                text,
            });
        } else if self.started {
            self.completed = true;
            events.push(NormalizedEvent::PlanCompleted {
                item_id: self.item_id.clone(),
                text: self.accumulated_text.clone(),
            });
        }
        events
    }

    fn normalized_chunk(&mut self, parsed: AssistantTextChunk) -> Vec<NormalizedEvent> {
        let mut events = Vec::new();
        for segment in parsed.plan_segments {
            match segment {
                ProposedPlanSegment::Normal(delta) => {
                    self.push_normal_text(delta, &mut events);
                }
                ProposedPlanSegment::ProposedPlanStart => {
                    self.ensure_started(&mut events);
                }
                ProposedPlanSegment::ProposedPlanDelta(delta) => {
                    self.ensure_started(&mut events);
                    if !delta.is_empty() {
                        self.accumulated_text.push_str(&delta);
                        events.push(NormalizedEvent::PlanDelta {
                            item_id: self.item_id.clone(),
                            delta,
                        });
                    }
                }
                ProposedPlanSegment::ProposedPlanEnd => {}
            }
        }
        events
    }

    fn ensure_started(&mut self, events: &mut Vec<NormalizedEvent>) {
        if self.started || self.completed {
            return;
        }
        self.started = true;
        events.push(NormalizedEvent::PlanStarted {
            item_id: self.item_id.clone(),
        });
    }

    fn push_normal_text(&mut self, delta: String, events: &mut Vec<NormalizedEvent>) {
        if delta.is_empty() {
            return;
        }
        if !self.normal_text_started {
            if delta.chars().all(char::is_whitespace) {
                self.leading_normal_whitespace.push_str(&delta);
                return;
            }
            self.normal_text_started = true;
            let mut visible = std::mem::take(&mut self.leading_normal_whitespace);
            visible.push_str(&delta);
            events.push(NormalizedEvent::Delta(visible));
            return;
        }
        events.push(NormalizedEvent::Delta(delta));
    }
}

struct ProviderStreamNormalizer {
    plan: PlanTextNormalizer,
    saw_output_text_delta: bool,
}

impl ProviderStreamNormalizer {
    fn new(request_id: &str, plan_mode: bool) -> Self {
        Self {
            plan: PlanTextNormalizer::new(request_id, plan_mode),
            saw_output_text_delta: false,
        }
    }

    fn normalize(&mut self, event: ResponseEvent) -> Vec<NormalizedEvent> {
        match event {
            ResponseEvent::OutputTextDelta(delta) => {
                if !delta.is_empty() {
                    self.saw_output_text_delta = true;
                }
                self.plan.push_str(&delta)
            }
            ResponseEvent::OutputItemDone(item) => {
                let completed_text = assistant_response_text(&item);
                let mut events = Vec::new();
                if !self.saw_output_text_delta
                    && let Some(text) = completed_text.as_deref()
                    && !text.is_empty()
                {
                    events.extend(self.plan.push_str(text));
                }
                if completed_text.is_some() {
                    events.extend(
                        self.plan
                            .complete_with_response_text(completed_text.as_deref()),
                    );
                }
                if let Some(event) = normalize_event(ResponseEvent::OutputItemDone(item)) {
                    events.push(event);
                }
                events
            }
            ResponseEvent::Completed {
                response_id,
                token_usage,
                end_turn,
            } => {
                let mut events = self.plan.complete_with_response_text(None);
                if let Some(event) = normalize_event(ResponseEvent::Completed {
                    response_id,
                    token_usage,
                    end_turn,
                }) {
                    events.push(event);
                }
                events
            }
            event => normalize_event(event).into_iter().collect(),
        }
    }
}

fn assistant_response_text(item: &ResponseItem) -> Option<String> {
    let ResponseItem::Message { role, content, .. } = item else {
        return None;
    };
    if role != "assistant" {
        return None;
    }
    Some(
        content
            .iter()
            .filter_map(|content| match content {
                ContentItem::OutputText { text } => Some(text.as_str()),
                _ => None,
            })
            .collect(),
    )
}

pub(crate) fn decode_request(input: &[u8]) -> Result<OfficialResponseRequest, CoreError> {
    let request: OfficialResponseRequest =
        serde_json::from_slice(input).map_err(|_| CoreError::InvalidJson)?;
    validate_request(&request)?;
    Ok(request)
}

pub(crate) fn execute_stream(
    request: OfficialResponseRequest,
    first_sequence: u64,
    mut emit: impl FnMut(Vec<u8>) -> bool,
) -> Result<(), CoreError> {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|_| CoreError::Network)?;
    let encoder = RefCell::new(ProviderEventEncoder::new(
        &request.request_id,
        first_sequence,
    ));
    let emit = RefCell::new(&mut emit);
    runtime.block_on(stream_response(
        &request,
        || {
            let encoded = encoder.borrow_mut().started()?;
            emit_if_continuing(&mut **emit.borrow_mut(), encoded)
        },
        |event| {
            let encoded = encoder.borrow_mut().normalized(event)?;
            emit_if_continuing(&mut **emit.borrow_mut(), encoded)
        },
        || emit_if_continuing(&mut **emit.borrow_mut(), Vec::new()),
    ))
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct PreparedOfficialHttpHeader {
    pub(crate) name: String,
    pub(crate) value: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct PreparedOfficialHttpRequest {
    pub(crate) url: String,
    pub(crate) method: String,
    pub(crate) headers: Vec<PreparedOfficialHttpHeader>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) proxy_url: Option<String>,
    #[serde(rename = "bodyBase64", with = "prepared_body_base64")]
    pub(crate) body: Vec<u8>,
}

impl PreparedOfficialHttpRequest {
    #[cfg(test)]
    fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|header| header.name.eq_ignore_ascii_case(name))
            .map(|header| header.value.as_str())
    }
}

mod prepared_body_base64 {
    use base64::Engine;
    use serde::Serializer;

    pub(super) fn serialize<S>(body: &[u8], serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(&base64::engine::general_purpose::STANDARD.encode(body))
    }
}

struct NativeResponseHead {
    status: StatusCode,
    headers: HeaderMap,
}

#[derive(Clone)]
struct NativeProviderTransport {
    request_sender: std_mpsc::SyncSender<ProviderHttpRequest>,
    response_receiver: Arc<tokio::sync::Mutex<Option<oneshot::Receiver<NativeResponseHead>>>>,
    body_receiver: Arc<
        tokio::sync::Mutex<Option<futures_mpsc::UnboundedReceiver<Result<Bytes, TransportError>>>>,
    >,
}

impl HttpTransport for NativeProviderTransport {
    async fn execute(
        &self,
        _request: ProviderHttpRequest,
    ) -> Result<ProviderHttpResponse, TransportError> {
        Err(TransportError::Network(
            "native provider transport does not support buffered requests".to_string(),
        ))
    }

    async fn stream(&self, request: ProviderHttpRequest) -> Result<StreamResponse, TransportError> {
        self.request_sender
            .send(request)
            .map_err(|_| TransportError::Network("native request receiver closed".to_string()))?;
        let receiver = self.response_receiver.lock().await.take().ok_or_else(|| {
            TransportError::Network("native response already started".to_string())
        })?;
        let response = receiver.await.map_err(|_| {
            TransportError::Network("native response head was not delivered".to_string())
        })?;
        let mut body = self.body_receiver.lock().await.take().ok_or_else(|| {
            TransportError::Network("native response body already consumed".to_string())
        })?;
        if !response.status.is_success() {
            let mut bytes = Vec::new();
            while let Some(chunk) = body.next().await {
                bytes.extend_from_slice(&chunk?);
            }
            return Err(TransportError::Http {
                status: response.status,
                url: None,
                headers: Some(response.headers),
                body: String::from_utf8(bytes).ok(),
            });
        }
        Ok(StreamResponse {
            status: response.status,
            headers: response.headers,
            bytes: body.boxed(),
        })
    }
}

pub(crate) struct NativeOfficialStream {
    response_sender: Option<oneshot::Sender<NativeResponseHead>>,
    body_sender: Option<futures_mpsc::UnboundedSender<Result<Bytes, TransportError>>>,
    worker: Option<JoinHandle<NativeStreamCompletion>>,
    cancelled: bool,
}

pub(crate) struct NativeStreamCompletion {
    pub(crate) result: Result<(), CoreError>,
    pub(crate) emitted_count: u64,
}

impl NativeOfficialStream {
    pub(crate) fn begin_response(
        &mut self,
        status: u16,
        headers: Vec<(String, String)>,
    ) -> Result<(), CoreError> {
        let status = StatusCode::from_u16(status).map_err(|_| CoreError::InvalidArgument)?;
        let mut header_map = HeaderMap::new();
        for (name, value) in headers {
            let name =
                HeaderName::from_bytes(name.as_bytes()).map_err(|_| CoreError::InvalidArgument)?;
            let value = HeaderValue::from_str(&value).map_err(|_| CoreError::InvalidArgument)?;
            header_map.append(name, value);
        }
        self.response_sender
            .take()
            .ok_or(CoreError::InvalidArgument)?
            .send(NativeResponseHead {
                status,
                headers: header_map,
            })
            .map_err(|_| CoreError::Network)
    }

    pub(crate) fn push_body(&mut self, bytes: &[u8]) -> Result<(), CoreError> {
        if bytes.is_empty() {
            return Ok(());
        }
        self.body_sender
            .as_mut()
            .ok_or(CoreError::InvalidArgument)?
            .unbounded_send(Ok(Bytes::copy_from_slice(bytes)))
            .map_err(|_| CoreError::Network)
    }

    pub(crate) fn end_body(&mut self) -> Result<(), CoreError> {
        self.body_sender.take().ok_or(CoreError::InvalidArgument)?;
        Ok(())
    }

    pub(crate) fn cancel(&mut self) {
        self.cancelled = true;
        self.response_sender.take();
        if let Some(sender) = self.body_sender.take() {
            let _ = sender.unbounded_send(Err(TransportError::Network(
                "native provider stream cancelled".to_string(),
            )));
        }
    }

    pub(crate) fn finish(&mut self) -> NativeStreamCompletion {
        self.response_sender.take();
        self.body_sender.take();
        let Some(worker) = self.worker.take() else {
            return NativeStreamCompletion {
                result: Err(CoreError::InvalidArgument),
                emitted_count: 0,
            };
        };
        let Ok(mut completion) = worker.join() else {
            return NativeStreamCompletion {
                result: Err(CoreError::Network),
                emitted_count: 0,
            };
        };
        if self.cancelled {
            completion.result = Err(CoreError::Cancelled);
        }
        completion
    }
}

pub(crate) fn start_native_stream(
    request: OfficialResponseRequest,
    first_sequence: u64,
    mut emit: impl FnMut(Vec<u8>) -> bool + Send + 'static,
) -> Result<(PreparedOfficialHttpRequest, NativeOfficialStream), CoreError> {
    let proxy_url = request.proxy_url.clone();
    let (request_sender, request_receiver) = std_mpsc::sync_channel(1);
    let (response_sender, response_receiver) = oneshot::channel();
    let (body_sender, body_receiver) = futures_mpsc::unbounded();
    let transport = NativeProviderTransport {
        request_sender,
        response_receiver: Arc::new(tokio::sync::Mutex::new(Some(response_receiver))),
        body_receiver: Arc::new(tokio::sync::Mutex::new(Some(body_receiver))),
    };
    let worker = std::thread::spawn(move || {
        let runtime = match tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
        {
            Ok(runtime) => runtime,
            Err(_) => {
                return NativeStreamCompletion {
                    result: Err(CoreError::Network),
                    emitted_count: 0,
                };
            }
        };
        let encoder = RefCell::new(ProviderEventEncoder::new(
            &request.request_id,
            first_sequence,
        ));
        let emitted_count = std::cell::Cell::new(0_u64);
        let emit = RefCell::new(&mut emit);
        let result = runtime.block_on(stream_response_with_transport(
            &request,
            transport,
            || {
                let encoded = encoder.borrow_mut().started()?;
                emit_native_event(&mut **emit.borrow_mut(), &emitted_count, encoded)
            },
            |event| {
                let encoded = encoder.borrow_mut().normalized(event)?;
                emit_native_event(&mut **emit.borrow_mut(), &emitted_count, encoded)
            },
            || emit_if_continuing(&mut **emit.borrow_mut(), Vec::new()),
        ));
        NativeStreamCompletion {
            result,
            emitted_count: emitted_count.get(),
        }
    });
    let request = request_receiver
        .recv_timeout(NATIVE_PROVIDER_PREPARE_TIMEOUT)
        .map_err(|_| CoreError::Network)?;
    let prepared = prepared_http_request(&request, proxy_url)?;
    Ok((
        prepared,
        NativeOfficialStream {
            response_sender: Some(response_sender),
            body_sender: Some(body_sender),
            worker: Some(worker),
            cancelled: false,
        },
    ))
}

fn emit_native_event(
    emit: &mut impl FnMut(Vec<u8>) -> bool,
    emitted_count: &std::cell::Cell<u64>,
    event: Vec<u8>,
) -> Result<(), CoreError> {
    emit_if_continuing(emit, event)?;
    emitted_count.set(emitted_count.get() + 1);
    Ok(())
}

fn prepared_http_request(
    request: &ProviderHttpRequest,
    proxy_url: Option<String>,
) -> Result<PreparedOfficialHttpRequest, CoreError> {
    let prepared = request
        .prepare_body_for_send()
        .map_err(|_| CoreError::InvalidArgument)?;
    let headers = prepared
        .headers
        .iter()
        .filter_map(|(name, value)| {
            value.to_str().ok().map(|value| PreparedOfficialHttpHeader {
                name: name.as_str().to_string(),
                value: value.to_string(),
            })
        })
        .collect();
    Ok(PreparedOfficialHttpRequest {
        url: request.url.clone(),
        method: request.method.as_str().to_string(),
        headers,
        proxy_url,
        body: prepared.body.map_or_else(Vec::new, |body| body.to_vec()),
    })
}

async fn stream_response(
    request: &OfficialResponseRequest,
    report_connected: impl FnMut() -> Result<(), CoreError>,
    emit: impl FnMut(NormalizedEvent) -> Result<(), CoreError>,
    check_cancellation: impl FnMut() -> Result<(), CoreError>,
) -> Result<(), CoreError> {
    let mut client_builder = reqwest::Client::builder()
        // The iOS static library must not fall back to native-tls/OpenSSL:
        // an app bundle has no conventional CA-file path. WebPKI roots
        // make the official HTTPS provider deterministic on simulator and
        // device while preserving certificate verification.
        .use_rustls_tls()
        .https_only(true);
    if let Some(proxy_url) = request.proxy_url.as_deref() {
        let proxy = reqwest::Proxy::all(proxy_url).map_err(|_| CoreError::InvalidArgument)?;
        client_builder = client_builder.proxy(proxy);
    }
    let transport = ReqwestTransport::new(client_builder.build().map_err(|_| CoreError::Network)?);
    stream_response_with_transport(
        request,
        transport,
        report_connected,
        emit,
        check_cancellation,
    )
    .await
}

async fn stream_response_with_transport<T: HttpTransport>(
    request: &OfficialResponseRequest,
    transport: T,
    mut report_connected: impl FnMut() -> Result<(), CoreError>,
    mut emit: impl FnMut(NormalizedEvent) -> Result<(), CoreError>,
    mut check_cancellation: impl FnMut() -> Result<(), CoreError>,
) -> Result<(), CoreError> {
    let provider = provider_for(request);
    let auth = Arc::new(BearerAuth {
        token: request.access_token.clone(),
        account_id: request.account_id.clone(),
    });
    let client = ResponsesClient::new(transport, provider, auth);
    let mut headers = HeaderMap::new();
    headers.insert("originator", HeaderValue::from_static("codex_cli_rs"));
    let mut stream = match open_provider_stream(
        client.stream(response_body(request), headers, Compression::None, None),
        PROVIDER_RESPONSE_HEADERS_TIMEOUT,
        &mut report_connected,
    )
    .await
    {
        Ok(stream) => stream,
        Err(ProviderStreamOpenError::Upstream(error)) => {
            emit(NormalizedEvent::Realtime {
                event_type: "provider_transport_error",
                payload: provider_error_payload(&error),
            })?;
            return Err(CoreError::Network);
        }
        Err(ProviderStreamOpenError::Timeout) => {
            emit(NormalizedEvent::Realtime {
                event_type: "provider_transport_error",
                payload: provider_transport_timeout_payload("response_headers"),
            })?;
            return Err(CoreError::Network);
        }
        Err(ProviderStreamOpenError::ReportConnected(error)) => return Err(error),
    };

    let mut normalizer = ProviderStreamNormalizer::new(&request.request_id, request.plan_mode);
    let mut completed = false;
    let mut cancellation_poll = tokio::time::interval(Duration::from_millis(100));
    loop {
        let event = tokio::select! {
            _ = cancellation_poll.tick() => {
                check_cancellation()?;
                continue;
            }
            event = stream.next() => event,
        };
        let Some(event) = event else {
            break;
        };
        let event = match event {
            Ok(event) => event,
            Err(error) => {
                emit(NormalizedEvent::Realtime {
                    event_type: "provider_transport_error",
                    payload: provider_error_payload(&error),
                })?;
                return Err(CoreError::Network);
            }
        };
        for event in normalizer.normalize(event) {
            completed |= matches!(event, NormalizedEvent::Completed { .. });
            emit(event)?;
        }
    }
    if !completed {
        return Err(CoreError::Network);
    }
    Ok(())
}

#[derive(Debug)]
enum ProviderStreamOpenError<E> {
    Timeout,
    Upstream(E),
    ReportConnected(CoreError),
}

async fn open_provider_stream<F, Stream, Error>(
    future: F,
    timeout: Duration,
    mut report_connected: impl FnMut() -> Result<(), CoreError>,
) -> Result<Stream, ProviderStreamOpenError<Error>>
where
    F: Future<Output = Result<Stream, Error>>,
{
    let stream = tokio::time::timeout(timeout, future)
        .await
        .map_err(|_| ProviderStreamOpenError::Timeout)?
        .map_err(ProviderStreamOpenError::Upstream)?;
    report_connected().map_err(ProviderStreamOpenError::ReportConnected)?;
    Ok(stream)
}

fn provider_error_payload(error: &ApiError) -> serde_json::Value {
    let (message, status, body) = match error {
        ApiError::Transport(TransportError::Http { status, body, .. }) => (
            "Official provider HTTP request failed.",
            Some(status.as_u16()),
            body.as_deref(),
        ),
        ApiError::Api { status, message } => (
            "Official provider API request failed.",
            Some(status.as_u16()),
            Some(message.as_str()),
        ),
        ApiError::Transport(_) => ("Official provider transport failed.", None, None),
        ApiError::Stream(_) => ("Official provider stream failed.", None, None),
        _ => ("Official provider request failed.", None, None),
    };
    let mut payload = serde_json::Map::from_iter([(
        "message".to_string(),
        serde_json::Value::String(message.to_string()),
    )]);
    if let Some(status) = status {
        payload.insert("status".to_string(), json!(status));
    }
    if let Some(code) = body.and_then(provider_error_code) {
        payload.insert("code".to_string(), json!(code));
    }
    if let Some(detail) = body.and_then(provider_error_detail) {
        payload.insert("detail".to_string(), json!(detail));
    }
    serde_json::Value::Object(payload)
}

fn provider_transport_timeout_payload(stage: &str) -> serde_json::Value {
    json!({
        "message": "Official provider response headers timed out.",
        "stage": stage,
        "code": format!("{stage}_timeout"),
    })
}

fn provider_error_code(body: &str) -> Option<String> {
    let parsed: serde_json::Value = serde_json::from_str(body).ok()?;
    let root = parsed.as_object()?;
    let error = root.get("error").and_then(serde_json::Value::as_object);
    ["code", "error_code", "type"].into_iter().find_map(|key| {
        root.get(key)
            .and_then(serde_json::Value::as_str)
            .or_else(|| error?.get(key).and_then(serde_json::Value::as_str))
            .map(str::to_string)
    })
}

/// Keep a bounded, printable provider message for diagnosing rejected
/// requests without copying an arbitrary response body into diagnostics.
fn provider_error_detail(body: &str) -> Option<String> {
    let parsed: serde_json::Value = serde_json::from_str(body).ok()?;
    let root = parsed.as_object()?;
    let error = root.get("error").and_then(serde_json::Value::as_object);
    let message = root
        .get("message")
        .and_then(serde_json::Value::as_str)
        .or_else(|| error?.get("message").and_then(serde_json::Value::as_str))?;
    let lowered = message.to_ascii_lowercase();
    if [
        "authorization",
        "cookie",
        "password",
        "refresh_token",
        "secret",
        "token",
    ]
    .iter()
    .any(|marker| lowered.contains(marker))
    {
        return None;
    }
    let mut detail = String::with_capacity(message.len().min(240));
    for character in message.chars() {
        if detail.len() >= 240 {
            break;
        }
        if character.is_ascii_graphic() || character == ' ' {
            detail.push(character);
        }
    }
    (!detail.is_empty()).then_some(detail)
}

fn emit_if_continuing(
    emit: &mut impl FnMut(Vec<u8>) -> bool,
    event: Vec<u8>,
) -> Result<(), CoreError> {
    if emit(event) {
        Ok(())
    } else {
        Err(CoreError::Cancelled)
    }
}

fn provider_for(request: &OfficialResponseRequest) -> Provider {
    Provider {
        name: "openai".to_string(),
        base_url: request
            .base_url
            .clone()
            .unwrap_or_else(|| CHATGPT_CODEX_BASE_URL.to_string()),
        query_params: None,
        headers: HeaderMap::new(),
        retry: RetryConfig {
            max_attempts: 4,
            base_delay: Duration::from_millis(250),
            retry_429: true,
            retry_5xx: true,
            retry_transport: true,
        },
        stream_idle_timeout: Duration::from_secs(300),
    }
}

fn response_body(request: &OfficialResponseRequest) -> serde_json::Value {
    let mut input =
        Vec::with_capacity(request.prior_input_items.len() + request.input_history.len() + 1);
    for item in &request.prior_input_items {
        if let Ok(item) = serde_json::from_str(item) {
            input.push(item);
        }
    }
    input.push(json!({
        "type": "message",
        "role": "user",
        "content": response_content(&request.input)
    }));
    for item in &request.input_history {
        if let Ok(item) = serde_json::from_str(item) {
            input.push(item);
        }
    }
    let mut tools = if request.workspace_tools {
        workspace_tool_specs()
    } else {
        Vec::new()
    };
    if request.mcp_resource_tools {
        tools.extend(mcp_resource_tool_specs());
    }
    if request.request_user_input_tool {
        tools.push(request_user_input_tool_spec());
    }
    if request.request_permissions_tool {
        tools.push(request_permissions_tool_spec());
    }
    if request.update_plan_tool {
        tools.push(update_plan_tool_spec());
    }
    if request.view_image_tool {
        tools.push(view_image_tool_spec());
    }
    if !request.tool_search_sources.is_empty() {
        tools.push(tool_search_tool_spec(&request.tool_search_sources));
    }
    tools.extend(
        request
            .dynamic_tools
            .iter()
            .filter_map(dynamic_tool_response_spec),
    );
    let instructions = response_instructions(request);
    let model = provider_model(request);
    let mut body = json!({
        "model": model,
        "reasoning": {
            "effort": request.reasoning_effort
        },
        "instructions": instructions,
        "input": input,
        "tools": tools,
        "tool_choice": "auto",
        "parallel_tool_calls": false,
        "store": false,
        "stream": true,
        // The official Responses client requests encrypted reasoning content on
        // every streamed turn. Keeping this field aligned matters even when
        // the iPad renderer does not display the encrypted payload directly.
        "include": ["reasoning.encrypted_content"]
    });
    if let Some(schema) = request.output_schema.as_ref() {
        body["text"] = json!({
            "format": {
                "type": "json_schema",
                "strict": true,
                "schema": schema,
                "name": "codex_output_schema"
            }
        });
    }
    body
}

fn dynamic_function_response_spec(tool: &OfficialDynamicToolFunctionSpec) -> Value {
    json!({
        "type": "function",
        "name": tool.name,
        "description": tool.description,
        "strict": false,
        "parameters": tool.input_schema,
    })
}

fn dynamic_tool_response_spec(tool: &OfficialDynamicToolSpec) -> Option<Value> {
    match tool {
        OfficialDynamicToolSpec::Function(function) => {
            (!function.defer_loading).then(|| dynamic_function_response_spec(function))
        }
        OfficialDynamicToolSpec::Namespace(namespace) => {
            let tools = namespace
                .tools
                .iter()
                .filter_map(|tool| match tool {
                    OfficialDynamicToolNamespaceTool::Function(function)
                        if !function.defer_loading =>
                    {
                        Some(dynamic_function_response_spec(function))
                    }
                    OfficialDynamicToolNamespaceTool::Function(_) => None,
                })
                .collect::<Vec<_>>();
            (!tools.is_empty()).then(|| {
                json!({
                    "type": "namespace",
                    "name": namespace.name,
                    "description": namespace.description,
                    "tools": tools,
                })
            })
        }
    }
}

fn provider_model(request: &OfficialResponseRequest) -> &str {
    if is_chatgpt_provider(request)
        && matches!(request.model.as_str(), "gpt-5-6" | "gpt-5.6-sol")
    {
        // The desktop catalog can advertise the latest renderer model while
        // the ChatGPT Codex route exposes a narrower account-backed set. The
        // current route accepts gpt-5.5; keep this fallback scoped to ChatGPT
        // accounts so API-key and custom-provider model names remain intact.
        "gpt-5.5"
    } else if request.model == "gpt-5-6" && is_official_openai_provider(request) {
        "gpt-5.6-sol"
    } else {
        &request.model
    }
}

fn is_chatgpt_provider(request: &OfficialResponseRequest) -> bool {
    let Some(base_url) = request.base_url.as_deref() else {
        return true;
    };
    reqwest::Url::parse(base_url).is_ok_and(|url| {
        url.host_str() == Some("chatgpt.com")
            && url.path().starts_with("/backend-api/codex")
    })
}

fn is_official_openai_provider(request: &OfficialResponseRequest) -> bool {
    let Some(base_url) = request.base_url.as_deref() else {
        return true;
    };
    reqwest::Url::parse(base_url).is_ok_and(|url| {
        matches!(url.host_str(), Some("chatgpt.com") | Some("api.openai.com"))
            && (url.host_str() == Some("api.openai.com")
                || url.path().starts_with("/backend-api/codex"))
    })
}

fn response_instructions(request: &OfficialResponseRequest) -> String {
    let collaboration_instructions = request
        .collaboration_instructions
        .as_deref()
        .filter(|value| !value.trim().is_empty())
        .or_else(|| request.plan_mode.then_some(OFFICIAL_PLAN_MODE_INSTRUCTIONS));
    let Some(collaboration_instructions) = collaboration_instructions else {
        return request.instructions.clone();
    };
    let base = request.instructions.trim_end();
    if base.is_empty() {
        collaboration_instructions.to_string()
    } else {
        format!("{base}\n\n{collaboration_instructions}")
    }
}

fn response_content(input: &[OfficialUserInput]) -> Vec<serde_json::Value> {
    input
        .iter()
        .map(|item| match item {
            OfficialUserInput::Text {
                text,
                text_elements,
            } => {
                let mut content = json!({
                    "type": "input_text",
                    "text": text
                });
                if !text_elements.is_empty() {
                    content["text_elements"] = json!(text_elements);
                }
                content
            }
            OfficialUserInput::Image { detail, url } => {
                image_content(url.clone(), detail.as_deref())
            }
            OfficialUserInput::LocalImage { detail, path } => {
                match local_media_data_url(path, true) {
                    Ok(url) => image_content(url, detail.as_deref()),
                    Err(message) => media_error_content("image", path, &message),
                }
            }
            OfficialUserInput::Audio { url } => json!({
                "type": "input_audio",
                "audio_url": url
            }),
            OfficialUserInput::LocalAudio { path } => match local_media_data_url(path, false) {
                Ok(url) => json!({
                    "type": "input_audio",
                    "audio_url": url
                }),
                Err(message) => media_error_content("audio", path, &message),
            },
            OfficialUserInput::Skill { name, path } => {
                let body = std::fs::read_to_string(path)
                    .unwrap_or_else(|error| format!("[skill file unavailable: {error}]"));
                json!({
                    "type": "input_text",
                    "text": format!(
                        "<skill name={name:?} path={path:?}>\\n{body}\\n</skill>"
                    )
                })
            }
            OfficialUserInput::Mention { name, path } => json!({
                "type": "input_text",
                "text": format!("[mention:{name}]({path})")
            }),
        })
        .collect()
}

fn image_content(url: String, detail: Option<&str>) -> serde_json::Value {
    let mut content = json!({
        "type": "input_image",
        "image_url": url
    });
    if let Some(detail) = detail {
        content["detail"] = json!(detail);
    }
    content
}

fn media_error_content(kind: &str, path: &str, message: &str) -> serde_json::Value {
    json!({
        "type": "input_text",
        "text": format!("[{kind} unavailable at {path}: {message}]")
    })
}

fn local_media_data_url(path: &str, image: bool) -> Result<String, String> {
    let bytes = std::fs::read(path).map_err(|error| error.to_string())?;
    let extension = std::path::Path::new(path)
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    let mime = match (image, extension.as_str()) {
        (true, "png") => "image/png",
        (true, "jpg" | "jpeg") => "image/jpeg",
        (true, "gif") => "image/gif",
        (true, "webp") => "image/webp",
        (true, "heic" | "heif") => "image/heic",
        (true, _) => "application/octet-stream",
        (false, "wav") => "audio/wav",
        (false, "mp3") => "audio/mpeg",
        (false, "m4a") => "audio/mp4",
        (false, "aac") => "audio/aac",
        (false, "ogg" | "oga") => "audio/ogg",
        (false, "flac") => "audio/flac",
        (false, _) => "application/octet-stream",
    };
    Ok(format!(
        "data:{mime};base64,{}",
        base64::engine::general_purpose::STANDARD.encode(bytes)
    ))
}

fn mcp_resource_tool_specs() -> Vec<serde_json::Value> {
    vec![
        json!({
            "type": "function",
            "name": "list_mcp_resources",
            "description": "Lists resources provided by MCP servers. Resources allow servers to share data that provides context to language models, such as files, database schemas, or application-specific information. Prefer resources over web search when possible.",
            "strict": false,
            "parameters": {
                "type": "object",
                "properties": {
                    "server": {
                        "type": "string",
                        "description": "MCP server name. Omit to list resources from every configured server."
                    },
                    "cursor": {
                        "type": "string",
                        "description": "Opaque cursor from a previous list_mcp_resources call; omit for the first page."
                    }
                },
                "additionalProperties": false
            }
        }),
        json!({
            "type": "function",
            "name": "list_mcp_resource_templates",
            "description": "Lists resource templates provided by MCP servers. Parameterized resource templates allow servers to share data that takes parameters and provides context to language models, such as files, database schemas, or application-specific information. Prefer resource templates over web search when possible.",
            "strict": false,
            "parameters": {
                "type": "object",
                "properties": {
                    "server": {
                        "type": "string",
                        "description": "MCP server name. Omit to list resource templates from every configured server."
                    },
                    "cursor": {
                        "type": "string",
                        "description": "Opaque cursor from a previous list_mcp_resource_templates call; omit for the first page."
                    }
                },
                "additionalProperties": false
            }
        }),
        json!({
            "type": "function",
            "name": "read_mcp_resource",
            "description": "Read a specific resource from an MCP server given the server name and resource URI.",
            "strict": false,
            "parameters": {
                "type": "object",
                "properties": {
                    "server": {
                        "type": "string",
                        "description": "MCP server name exactly as configured. Must match the 'server' field returned by list_mcp_resources."
                    },
                    "uri": {
                        "type": "string",
                        "description": "Resource URI to read. Must be one of the URIs returned by list_mcp_resources."
                    }
                },
                "required": ["server", "uri"],
                "additionalProperties": false
            }
        }),
    ]
}

fn tool_search_tool_spec(searchable_sources: &[OfficialToolSearchSource]) -> serde_json::Value {
    let mut source_descriptions = BTreeMap::new();
    for source in searchable_sources {
        source_descriptions
            .entry(source.name.clone())
            .and_modify(|existing: &mut Option<String>| {
                if existing.is_none() {
                    *existing = source.description.clone();
                }
            })
            .or_insert_with(|| source.description.clone());
    }
    let source_descriptions = source_descriptions
        .into_iter()
        .map(|(name, description)| match description {
            Some(description) => format!("- {name}: {description}"),
            None => format!("- {name}"),
        })
        .collect::<Vec<_>>()
        .join("\n");
    let source_section = format!(
        "\n\nYou have access to tools from the following sources:\n{source_descriptions}\n"
    );
    let description = format!(
        "# Tool discovery\n\nSearches over deferred tool metadata with BM25 and exposes matching tools for the next model call.{source_section}Some of the tools may not have been provided to you upfront, and you should use this tool (`tool_search`) to search for the required tools. For MCP tool discovery, always use `tool_search` instead of `list_mcp_resources` or `list_mcp_resource_templates`."
    );

    json!({
        "type": "tool_search",
        "execution": "client",
        "description": description,
        "parameters": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Search query for deferred tools."
                },
                "limit": {
                    "type": "number",
                    "description": "Maximum number of tools to return. Defaults to 8."
                }
            },
            "required": ["query"],
            "additionalProperties": false
        }
    })
}

fn request_user_input_tool_spec() -> serde_json::Value {
    json!({
        "type": "function",
        "name": "request_user_input",
        "description": "Request user input for one to three short questions and wait for the response. Set autoResolutionMs, from 60000 to 240000 milliseconds, only when the question is useful but non-blocking and continuing with best judgment is acceptable if the user does not answer; omit it when explicit user input is required.",
        "strict": false,
        "parameters": {
            "type": "object",
            "properties": {
                "questions": {
                    "type": "array",
                    "description": "Questions to show the user. Prefer 1 and do not exceed 3",
                    "items": {
                        "type": "object",
                        "properties": {
                            "id": {
                                "type": "string",
                                "description": "Stable identifier for mapping answers (snake_case)."
                            },
                            "header": {
                                "type": "string",
                                "description": "Short header label shown in the UI (12 or fewer chars)."
                            },
                            "question": {
                                "type": "string",
                                "description": "Single-sentence prompt shown to the user."
                            },
                            "options": {
                                "type": "array",
                                "description": "Provide 2-3 mutually exclusive choices. Put the recommended option first and suffix its label with \"(Recommended)\". Do not include an \"Other\" option in this list; the client will add a free-form \"Other\" option automatically.",
                                "items": {
                                    "type": "object",
                                    "properties": {
                                        "label": {
                                            "type": "string",
                                            "description": "User-facing label (1-5 words)."
                                        },
                                        "description": {
                                            "type": "string",
                                            "description": "One short sentence explaining impact/tradeoff if selected."
                                        }
                                    },
                                    "required": ["label", "description"],
                                    "additionalProperties": false
                                }
                            }
                        },
                        "required": ["id", "header", "question", "options"],
                        "additionalProperties": false
                    }
                },
                "autoResolutionMs": {
                    "type": "number",
                    "description": "Optional auto-resolution window in milliseconds, from 60000 to 240000. Include this only when the question is useful but non-blocking and continuing with best judgment is acceptable if the user does not answer; omit it when explicit user input is required before continuing. Use 60000 for lightly helpful context and up to 240000 when the answer would materially unblock better work."
                }
            },
            "required": ["questions"],
            "additionalProperties": false
        }
    })
}

fn request_permissions_tool_spec() -> serde_json::Value {
    json!({
        "type": "function",
        "name": "request_permissions",
        "description": "Request additional filesystem or network permissions from the user and wait for the client to grant a subset of the requested permission profile. Use environment_id to target a specific attached environment; omit it to use the primary environment. Relative filesystem paths resolve against the selected environment cwd. Granted permissions apply automatically to later shell-like commands in the current turn, or for the rest of the session if the client approves them at session scope.",
        "strict": false,
        "parameters": {
            "type": "object",
            "properties": {
                "reason": {
                    "type": "string",
                    "description": "Optional short explanation for why additional permissions are needed."
                },
                "environment_id": {
                    "type": "string",
                    "description": "Environment id from <environment_context>. Omit to use the primary environment."
                },
                "permissions": {
                    "type": "object",
                    "description": "Filesystem or network access request.",
                    "properties": {
                        "network": {
                            "type": "object",
                            "description": "Network access request.",
                            "properties": {
                                "enabled": {
                                    "type": "boolean",
                                    "description": "True requests network access; false or omitted requests none."
                                }
                            },
                            "additionalProperties": false
                        },
                        "file_system": {
                            "type": "object",
                            "description": "Filesystem access request.",
                            "properties": {
                                "read": {
                                    "type": "array",
                                    "description": "Absolute paths to grant read access; omit when none are needed.",
                                    "items": {"type": "string"}
                                },
                                "write": {
                                    "type": "array",
                                    "description": "Absolute paths to grant write access; omit when none are needed.",
                                    "items": {"type": "string"}
                                }
                            },
                            "additionalProperties": false
                        }
                    },
                    "additionalProperties": false
                }
            },
            "required": ["permissions"],
            "additionalProperties": false
        }
    })
}

fn update_plan_tool_spec() -> serde_json::Value {
    json!({
        "type": "function",
        "name": "update_plan",
        "description": "Updates the task plan.\nProvide an optional explanation and a list of plan items, each with a step and status.\nAt most one step can be in_progress at a time.\n",
        "strict": false,
        "parameters": {
            "type": "object",
            "properties": {
                "explanation": {
                    "type": "string",
                    "description": "Optional explanation for this plan update."
                },
                "plan": {
                    "type": "array",
                    "description": "The list of steps",
                    "items": {
                        "type": "object",
                        "properties": {
                            "step": {
                                "type": "string",
                                "description": "Task step text."
                            },
                            "status": {
                                "type": "string",
                                "enum": ["pending", "in_progress", "completed"],
                                "description": "Step status."
                            }
                        },
                        "required": ["step", "status"],
                        "additionalProperties": false
                    }
                }
            },
            "required": ["plan"],
            "additionalProperties": false
        }
    })
}

fn view_image_tool_spec() -> serde_json::Value {
    json!({
        "type": "function",
        "name": "view_image",
        "description": "View a local image file from the filesystem when visual inspection is needed. Use this for images already available on disk.",
        "strict": false,
        "parameters": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Local filesystem path to an image file."
                },
                "detail": {
                    "type": "string",
                    "enum": ["high", "original"],
                    "description": "Image detail level. Defaults to `high`; use `original` to preserve exact resolution."
                }
            },
            "required": ["path"],
            "additionalProperties": false
        },
        "output_schema": {
            "type": "object",
            "properties": {
                "image_url": {
                    "type": "string",
                    "description": "Data URL for the loaded image."
                },
                "detail": {
                    "type": "string",
                    "enum": ["high", "original"],
                    "description": "Image detail hint returned by view_image. Returns `high` for default resized behavior or `original` when original resolution is preserved."
                }
            },
            "required": ["image_url", "detail"],
            "additionalProperties": false
        }
    })
}

fn unified_exec_output_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "properties": {
            "chunk_id": {
                "type": "string",
                "description": "Chunk identifier included when the response reports one."
            },
            "wall_time_seconds": {
                "type": "number",
                "description": "Elapsed wall time spent waiting for output in seconds."
            },
            "exit_code": {
                "type": "number",
                "description": "Process exit code when the command finished during this call."
            },
            "session_id": {
                "type": "number",
                "description": "Session identifier to pass to write_stdin when the process is still running."
            },
            "original_token_count": {
                "type": "number",
                "description": "Approximate token count before output truncation."
            },
            "output": {
                "type": "string",
                "description": "Command output text, possibly truncated."
            }
        },
        "required": ["wall_time_seconds", "output"],
        "additionalProperties": false
    })
}

fn workspace_tool_specs() -> Vec<serde_json::Value> {
    vec![
        json!({
            "type": "function",
            "name": "list_workspace_files",
            "description": "List files and directories in the selected iPad workspace.",
            "strict": true,
            "parameters": {
                "type": "object",
                "properties": {
                    "limit": {"type": ["integer", "null"], "minimum": 1, "maximum": 2000}
                },
                "required": ["limit"],
                "additionalProperties": false
            }
        }),
        json!({
            "type": "function",
            "name": "read_workspace_file",
            "description": "Read one UTF-8 text file from the selected iPad workspace.",
            "strict": true,
            "parameters": {
                "type": "object",
                "properties": {"path": {"type": "string"}},
                "required": ["path"],
                "additionalProperties": false
            }
        }),
        json!({
            "type": "function",
            "name": "search_workspace_text",
            "description": "Search UTF-8 project files and return matching paths, line numbers, and text.",
            "strict": true,
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string"},
                    "limit": {"type": ["integer", "null"], "minimum": 1, "maximum": 500}
                },
                "required": ["query", "limit"],
                "additionalProperties": false
            }
        }),
        json!({
            "type": "function",
            "name": "write_workspace_file",
            "description": "Create or replace one UTF-8 text file inside the selected iPad workspace.",
            "strict": true,
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string"},
                    "text": {"type": "string"}
                },
                "required": ["path", "text"],
                "additionalProperties": false
            }
        }),
        json!({
            "type": "function",
            "name": "exec_command",
            "description": "Runs a command in a PTY, returning output or a session ID for ongoing interaction.",
            "strict": false,
            "parameters": {
                "type": "object",
                "properties": {
                    "cmd": {
                        "type": "string",
                        "description": "Shell command to execute."
                    },
                    "workdir": {
                        "type": "string",
                        "description": "Working directory for the command. Defaults to the turn cwd."
                    },
                    "shell": {
                        "type": "string",
                        "description": "Shell binary to launch. Defaults to the user's default shell."
                    },
                    "login": {
                        "type": "boolean",
                        "description": "True runs the shell with -l/-i semantics; false disables them. Defaults to true."
                    },
                    "tty": {
                        "type": "boolean",
                        "description": "True allocates a PTY for the command; false or omitted uses plain pipes."
                    },
                    "yield_time_ms": {
                        "type": "number",
                        "description": "Wait before yielding output. Defaults to 10000 ms; effective range is 250-30000 ms."
                    },
                    "max_output_tokens": {
                        "type": "number",
                        "description": "Output token budget. Defaults to 10000 tokens; larger requests may be capped by policy."
                    }
                },
                "required": ["cmd"],
                "additionalProperties": false
            },
            "output_schema": unified_exec_output_schema()
        }),
        json!({
            "type": "function",
            "name": "write_stdin",
            "description": "Writes characters to an existing unified exec session and returns recent output.",
            "strict": false,
            "parameters": {
                "type": "object",
                "properties": {
                    "session_id": {
                        "type": "number",
                        "description": "Identifier of the running unified exec session."
                    },
                    "chars": {
                        "type": "string",
                        "description": "Bytes to write to stdin. Defaults to empty, which polls without writing."
                    },
                    "yield_time_ms": {
                        "type": "number",
                        "description": "Wait before yielding output. Non-empty writes default to 250 ms and cap at 30000 ms; empty polls wait 5000-300000 ms by default."
                    },
                    "max_output_tokens": {
                        "type": "number",
                        "description": "Output token budget. Defaults to 10000 tokens; larger requests may be capped by policy."
                    }
                },
                "required": ["session_id"],
                "additionalProperties": false
            },
            "output_schema": unified_exec_output_schema()
        }),
        json!({
            "type": "custom",
            "name": "apply_patch",
            "description": "The `apply_patch` tool can be used to edit files. This is a FREEFORM tool, so do not wrap the patch in JSON.",
            "format": {
                "type": "grammar",
                "syntax": "lark",
                "definition": APPLY_PATCH_LARK_GRAMMAR
            }
        }),
    ]
}

fn normalize_event(event: ResponseEvent) -> Option<NormalizedEvent> {
    match event {
        ResponseEvent::Created => Some(NormalizedEvent::Realtime {
            event_type: "created",
            payload: json!({}),
        }),
        ResponseEvent::SafetyBuffering(value) => Some(NormalizedEvent::Realtime {
            event_type: "safety_buffering",
            payload: json!({
                "use_cases": value.use_cases,
                "reasons": value.reasons,
                "show_buffering_ui": value.show_buffering_ui,
                "faster_model": value.faster_model,
            }),
        }),
        ResponseEvent::OutputTextDelta(delta) => Some(NormalizedEvent::Delta(delta)),
        ResponseEvent::OutputItemAdded(item) => Some(NormalizedEvent::Realtime {
            event_type: "output_item_added",
            payload: serde_json::to_value(item).ok()?,
        }),
        ResponseEvent::OutputItemDone(item) => {
            let item_json = serde_json::to_string(&item).ok()?;
            match item {
                ResponseItem::FunctionCall {
                    name,
                    arguments,
                    call_id,
                    ..
                } => Some(NormalizedEvent::ToolCall {
                    name,
                    arguments,
                    call_id,
                    item_json,
                }),
                ResponseItem::CustomToolCall {
                    name,
                    input,
                    call_id,
                    ..
                } => Some(NormalizedEvent::ToolCall {
                    name,
                    arguments: input,
                    call_id,
                    item_json,
                }),
                _ => Some(NormalizedEvent::ResponseItem(item_json)),
            }
        }
        ResponseEvent::Completed {
            response_id,
            token_usage,
            end_turn,
        } => Some(NormalizedEvent::Completed {
            response_id,
            usage: token_usage.map(Into::into),
            // The official Codex loop treats only an explicit `false` as a
            // follow-up request. Responses API deployments commonly omit the
            // field for a terminal response, so expose that semantic as an
            // explicit `true` to the durable iPad turn coordinator.
            end_turn: Some(end_turn.unwrap_or(true)),
        }),
        ResponseEvent::ServerModel(model) => Some(NormalizedEvent::Realtime {
            event_type: "server_model",
            payload: json!({ "model": model }),
        }),
        ResponseEvent::ModelVerifications(verifications) => Some(NormalizedEvent::Realtime {
            event_type: "model_verifications",
            payload: json!({ "verifications": verifications }),
        }),
        ResponseEvent::TurnModerationMetadata(metadata) => Some(NormalizedEvent::Realtime {
            event_type: "turn_moderation_metadata",
            payload: serde_json::to_value(metadata).ok()?,
        }),
        ResponseEvent::ServerReasoningIncluded(included) => Some(NormalizedEvent::Realtime {
            event_type: "server_reasoning_included",
            payload: json!({ "included": included }),
        }),
        ResponseEvent::ToolCallInputDelta {
            item_id,
            call_id,
            delta,
        } => Some(NormalizedEvent::Realtime {
            event_type: "tool_call_input_delta",
            payload: json!({
                "item_id": item_id,
                "call_id": call_id,
                "delta": delta,
            }),
        }),
        ResponseEvent::ReasoningSummaryDelta {
            delta,
            summary_index,
        } => Some(NormalizedEvent::Realtime {
            event_type: "reasoning_summary_delta",
            payload: json!({
                "delta": delta,
                "summary_index": summary_index,
            }),
        }),
        ResponseEvent::ReasoningSummaryDone {
            item_id,
            text,
            summary_index,
        } => Some(NormalizedEvent::Realtime {
            event_type: "reasoning_summary_done",
            payload: json!({
                "item_id": item_id,
                "text": text,
                "summary_index": summary_index,
            }),
        }),
        ResponseEvent::ReasoningContentDelta {
            delta,
            content_index,
        } => Some(NormalizedEvent::Realtime {
            event_type: "reasoning_content_delta",
            payload: json!({
                "delta": delta,
                "content_index": content_index,
            }),
        }),
        ResponseEvent::ReasoningSummaryPartAdded { summary_index } => {
            Some(NormalizedEvent::Realtime {
                event_type: "reasoning_summary_part_added",
                payload: json!({ "summary_index": summary_index }),
            })
        }
        ResponseEvent::RateLimits(rate_limits) => Some(NormalizedEvent::Realtime {
            event_type: "rate_limits",
            payload: serde_json::to_value(rate_limits).ok()?,
        }),
        ResponseEvent::ModelsEtag(etag) => Some(NormalizedEvent::Realtime {
            event_type: "models_etag",
            payload: json!({ "etag": etag }),
        }),
    }
}

#[cfg(test)]
fn encode_events(
    request_id: &str,
    normalized: Vec<NormalizedEvent>,
    first_sequence: u64,
) -> Result<Vec<Vec<u8>>, CoreError> {
    let mut encoder = ProviderEventEncoder::new(request_id, first_sequence);
    let mut events = vec![encoder.started()?];
    for event in normalized {
        events.push(encoder.normalized(event)?);
    }
    Ok(events)
}

struct ProviderEventEncoder<'a> {
    request_id: &'a str,
    next_sequence: u64,
    emitted_count: u64,
}

impl<'a> ProviderEventEncoder<'a> {
    fn new(request_id: &'a str, first_sequence: u64) -> Self {
        Self {
            request_id,
            next_sequence: first_sequence,
            emitted_count: 0,
        }
    }

    fn started(&mut self) -> Result<Vec<u8>, CoreError> {
        let encoded = serde_json::to_vec(&ResponseStartedEvent {
            sequence: self.next_sequence,
            kind: "providerResponseStarted",
            request_id: self.request_id,
            source_commit: OFFICIAL_SOURCE_COMMIT,
        })
        .map_err(|_| CoreError::InvalidJson)?;
        self.advance();
        Ok(encoded)
    }

    fn normalized(&mut self, event: NormalizedEvent) -> Result<Vec<u8>, CoreError> {
        let encoded = match event {
            NormalizedEvent::Delta(delta) => serde_json::to_vec(&AssistantTextDeltaEvent {
                sequence: self.next_sequence,
                kind: "assistantTextDelta",
                request_id: self.request_id,
                delta: &delta,
            }),
            NormalizedEvent::PlanStarted { item_id } => serde_json::to_vec(&PlanStartedEvent {
                sequence: self.next_sequence,
                kind: "planStarted",
                request_id: self.request_id,
                item_id: &item_id,
            }),
            NormalizedEvent::PlanDelta { item_id, delta } => serde_json::to_vec(&PlanDeltaEvent {
                sequence: self.next_sequence,
                kind: "planDelta",
                request_id: self.request_id,
                item_id: &item_id,
                delta: &delta,
            }),
            NormalizedEvent::PlanCompleted { item_id, text } => {
                serde_json::to_vec(&PlanCompletedEvent {
                    sequence: self.next_sequence,
                    kind: "planCompleted",
                    request_id: self.request_id,
                    item_id: &item_id,
                    text: &text,
                })
            }
            NormalizedEvent::ResponseItem(item_json) => {
                serde_json::to_vec(&ResponseItemDoneEvent {
                    sequence: self.next_sequence,
                    kind: "providerResponseItemDone",
                    request_id: self.request_id,
                    item_json: &item_json,
                })
            }
            NormalizedEvent::ToolCall {
                name,
                arguments,
                call_id,
                item_json,
            } => serde_json::to_vec(&ToolCallRequestedEvent {
                sequence: self.next_sequence,
                kind: "toolCallRequested",
                request_id: self.request_id,
                name: &name,
                arguments: &arguments,
                call_id: &call_id,
                item_json: &item_json,
            }),
            NormalizedEvent::Realtime {
                event_type,
                payload,
            } => serde_json::to_vec(&ProviderRealtimeEvent {
                sequence: self.next_sequence,
                kind: "providerRealtimeEvent",
                request_id: self.request_id,
                event_type,
                payload: &payload,
            }),
            NormalizedEvent::Completed {
                response_id,
                usage,
                end_turn,
            } => serde_json::to_vec(&ResponseCompletedEvent {
                sequence: self.next_sequence,
                kind: "providerResponseCompleted",
                request_id: self.request_id,
                response_id: &response_id,
                usage: usage.as_ref(),
                end_turn,
            }),
        }
        .map_err(|_| CoreError::InvalidJson)?;
        self.advance();
        Ok(encoded)
    }

    #[cfg(test)]
    fn emitted_count(&self) -> u64 {
        self.emitted_count
    }

    fn advance(&mut self) {
        self.next_sequence += 1;
        self.emitted_count += 1;
    }
}

fn validate_request(request: &OfficialResponseRequest) -> Result<(), CoreError> {
    if request.request_id.trim().is_empty()
        || request.access_token.trim().is_empty()
        || request.model.trim().is_empty()
        || request.reasoning_effort.trim().is_empty()
        || request.input.is_empty()
        || !request.input.iter().any(valid_user_input)
        || request
            .account_id
            .as_deref()
            .is_some_and(|value| value.trim().is_empty())
    {
        return Err(CoreError::InvalidArgument);
    }
    let base_url = request
        .base_url
        .as_deref()
        .unwrap_or(CHATGPT_CODEX_BASE_URL);
    if !base_url.starts_with("https://") || base_url.ends_with('/') {
        return Err(CoreError::InvalidArgument);
    }
    if let Some(proxy_url) = request.proxy_url.as_deref() {
        let parsed = reqwest::Url::parse(proxy_url).map_err(|_| CoreError::InvalidArgument)?;
        if !matches!(parsed.scheme(), "http" | "https")
            || parsed.host_str().is_none()
            || !parsed.username().is_empty()
            || parsed.password().is_some()
            || parsed.query().is_some()
            || parsed.fragment().is_some()
            || !matches!(parsed.path(), "" | "/")
        {
            return Err(CoreError::InvalidArgument);
        }
    }
    if request
        .prior_input_items
        .iter()
        .chain(&request.input_history)
        .any(|item| !is_supported_response_input_item(item))
    {
        return Err(CoreError::InvalidArgument);
    }
    Ok(())
}

fn valid_user_input(input: &OfficialUserInput) -> bool {
    match input {
        OfficialUserInput::Text { text, .. } => !text.trim().is_empty(),
        OfficialUserInput::Image { url, detail }
        | OfficialUserInput::LocalImage { path: url, detail } => {
            !url.trim().is_empty()
                && detail
                    .as_deref()
                    .is_none_or(|value| matches!(value, "auto" | "low" | "high" | "original"))
        }
        OfficialUserInput::Audio { url } | OfficialUserInput::LocalAudio { path: url } => {
            !url.trim().is_empty()
        }
        OfficialUserInput::Skill { name, path } | OfficialUserInput::Mention { name, path } => {
            !name.trim().is_empty() && !path.trim().is_empty()
        }
    }
}

fn is_supported_response_input_item(item: &str) -> bool {
    let Ok(response_item) = serde_json::from_str::<ResponseItem>(item) else {
        return false;
    };
    !matches!(response_item, ResponseItem::Other)
        && !response_item_contains_remote_image_url(&response_item)
}

fn response_item_contains_remote_image_url(item: &ResponseItem) -> bool {
    match item {
        ResponseItem::Message { content, .. } => content.iter().any(|item| {
            matches!(
                item,
                ContentItem::InputImage { image_url, .. }
                    if is_remote_image_url(image_url)
            )
        }),
        ResponseItem::FunctionCallOutput { output, .. }
        | ResponseItem::CustomToolCallOutput { output, .. } => {
            output.content_items().is_some_and(|content| {
                content.iter().any(|item| {
                    matches!(
                        item,
                        FunctionCallOutputContentItem::InputImage { image_url, .. }
                            if is_remote_image_url(image_url)
                    )
                })
            })
        }
        _ => false,
    }
}

fn is_remote_image_url(image_url: &str) -> bool {
    image_url.split_once(':').is_some_and(|(scheme, _)| {
        scheme.eq_ignore_ascii_case("http") || scheme.eq_ignore_ascii_case("https")
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn expected_unified_exec_output_schema() -> serde_json::Value {
        json!({
            "type": "object",
            "properties": {
                "chunk_id": {
                    "type": "string",
                    "description": "Chunk identifier included when the response reports one."
                },
                "wall_time_seconds": {
                    "type": "number",
                    "description": "Elapsed wall time spent waiting for output in seconds."
                },
                "exit_code": {
                    "type": "number",
                    "description": "Process exit code when the command finished during this call."
                },
                "session_id": {
                    "type": "number",
                    "description": "Session identifier to pass to write_stdin when the process is still running."
                },
                "original_token_count": {
                    "type": "number",
                    "description": "Approximate token count before output truncation."
                },
                "output": {
                    "type": "string",
                    "description": "Command output text, possibly truncated."
                }
            },
            "required": ["wall_time_seconds", "output"],
            "additionalProperties": false
        })
    }

    fn request() -> OfficialResponseRequest {
        OfficialResponseRequest {
            request_id: "request-1".to_string(),
            access_token: "secret-in-memory-only".to_string(),
            account_id: Some("account-1".to_string()),
            base_url: None,
            proxy_url: None,
            model: "gpt-test".to_string(),
            reasoning_effort: "high".to_string(),
            instructions: "Be precise.".to_string(),
            collaboration_instructions: None,
            output_schema: None,
            input: vec![OfficialUserInput::Text {
                text: "Inspect this project.".to_string(),
                text_elements: Vec::new(),
            }],
            workspace_tools: false,
            request_user_input_tool: false,
            request_permissions_tool: false,
            update_plan_tool: false,
            view_image_tool: false,
            mcp_resource_tools: false,
            plan_mode: false,
            tool_search_sources: Vec::new(),
            dynamic_tools: Vec::new(),
            prior_input_items: Vec::new(),
            input_history: Vec::new(),
        }
    }

    fn request_from_json(overrides: serde_json::Value) -> OfficialResponseRequest {
        let mut value = json!({
            "requestId": "request-tools",
            "accessToken": "secret-in-memory-only",
            "accountId": "account-1",
            "baseUrl": null,
            "model": "gpt-test",
            "reasoningEffort": "high",
            "instructions": "Be precise.",
            "input": [{
                "type": "text",
                "text": "Inspect tools.",
                "text_elements": []
            }]
        });
        let value = value.as_object_mut().expect("request object");
        for (key, value_override) in overrides.as_object().expect("override object") {
            value.insert(key.clone(), value_override.clone());
        }
        serde_json::from_value(serde_json::Value::Object(value.clone()))
            .expect("valid official response request")
    }

    #[test]
    fn provider_http_error_payload_exposes_only_status_and_structured_code() {
        let secret = "never-emit-this-access-token";
        let error = codex_api::ApiError::Transport(codex_api::TransportError::Http {
            status: http::StatusCode::UNAUTHORIZED,
            url: Some("https://chatgpt.com/backend-api/codex/responses".to_string()),
            headers: None,
            body: Some(format!(
                r#"{{"error":{{"code":"token_expired","message":"{secret}"}}}}"#
            )),
        });

        let payload = provider_error_payload(&error);

        assert_eq!(payload["status"], 401);
        assert_eq!(payload["code"], "token_expired");
        assert!(
            !serde_json::to_string(&payload)
                .expect("serializable payload")
                .contains(secret)
        );
    }

    #[test]
    fn provider_api_error_payload_reads_error_code_without_leaking_message() {
        let secret = "never-emit-this-refresh-token";
        let error = codex_api::ApiError::Api {
            status: http::StatusCode::UNAUTHORIZED,
            message: format!(
                r#"{{"error":{{"error_code":"token_expired","message":"{secret}"}}}}"#
            ),
        };

        let payload = provider_error_payload(&error);

        assert_eq!(payload["status"], 401);
        assert_eq!(payload["code"], "token_expired");
        assert!(
            !serde_json::to_string(&payload)
                .expect("serializable payload")
                .contains(secret)
        );
    }

    #[test]
    fn plan_mode_without_custom_instructions_uses_exact_official_template() {
        let request = request_from_json(json!({
            "planMode": true
        }));

        let body = response_body(&request);
        let instructions = body["instructions"]
            .as_str()
            .expect("response instructions");

        assert!(instructions.starts_with("Be precise.\n\n# Plan Mode (Conversational)\n"));
        assert!(
            instructions.contains(
                "When you present the official plan, wrap it in a `<proposed_plan>` block"
            )
        );
        assert!(instructions.ends_with("unchanged.\n"));
    }

    #[test]
    fn custom_collaboration_instructions_take_precedence_over_plan_template() {
        let request = request_from_json(json!({
            "planMode": true,
            "collaborationInstructions": "CUSTOM MODE INSTRUCTIONS"
        }));

        let body = response_body(&request);

        assert_eq!(
            body["instructions"],
            "Be precise.\n\nCUSTOM MODE INSTRUCTIONS"
        );
        assert!(
            !body["instructions"]
                .as_str()
                .unwrap()
                .contains("# Plan Mode (Conversational)")
        );
    }

    #[test]
    fn ordinary_mode_without_collaboration_instructions_preserves_base_exactly() {
        let request = request_from_json(json!({
            "planMode": false
        }));

        let body = response_body(&request);

        assert_eq!(body["instructions"], "Be precise.");
    }

    #[test]
    fn output_schema_uses_official_strict_text_format() {
        let schema = json!({
            "type": "object",
            "properties": {
                "summary": {"type": "string"}
            },
            "required": ["summary"],
            "additionalProperties": false
        });
        let request = request_from_json(json!({
            "outputSchema": schema.clone()
        }));

        let body = response_body(&request);

        assert_eq!(
            body["text"]["format"],
            json!({
                "type": "json_schema",
                "strict": true,
                "schema": schema,
                "name": "codex_output_schema"
            })
        );
    }

    #[test]
    fn response_without_output_schema_omits_text_controls() {
        let body = response_body(&request_from_json(json!({})));

        assert!(body.get("text").is_none());
    }

    fn assistant_item(text: &str) -> ResponseItem {
        serde_json::from_value(json!({
            "type": "message",
            "id": "message-final",
            "role": "assistant",
            "content": [{
                "type": "output_text",
                "text": text
            }]
        }))
        .expect("valid assistant response item")
    }

    #[test]
    fn plan_mode_defaults_false_and_decodes_true_explicitly() {
        assert!(!request_from_json(json!({})).plan_mode);
        assert!(request_from_json(json!({"planMode": true})).plan_mode);
    }

    #[test]
    fn plan_mode_parser_preserves_order_and_uses_authoritative_completion_text() {
        let mut parser = PlanTextNormalizer::new("request-plan", true);
        let mut events = Vec::new();
        for chunk in [
            "Intro\n<prop",
            "osed_plan>\n- inspect\n",
            "- implement\n</proposed_",
            "plan>\nOutro",
        ] {
            events.extend(parser.push_str(chunk));
        }
        events.extend(parser.complete_with_response_text(Some(
            "Intro\n<proposed_plan>\n- inspect final\n- implement final\n</proposed_plan>\nOutro",
        )));

        assert!(matches!(
            events.first(),
            Some(NormalizedEvent::Delta(delta)) if delta == "Intro\n"
        ));
        assert!(events.iter().any(|event| matches!(
            event,
            NormalizedEvent::PlanStarted { item_id }
                if item_id == "request-plan-plan"
        )));
        let plan_deltas = events
            .iter()
            .filter_map(|event| match event {
                NormalizedEvent::PlanDelta { delta, .. } => Some(delta.as_str()),
                _ => None,
            })
            .collect::<Vec<_>>();
        assert_eq!(plan_deltas, vec!["- inspect\n", "- implement\n"]);
        assert!(events.iter().any(|event| matches!(
            event,
            NormalizedEvent::Delta(delta) if delta == "Outro"
        )));
        assert!(events.iter().all(|event| !matches!(
            event,
            NormalizedEvent::Delta(delta)
                if delta.contains("inspect") || delta.contains("implement")
        )));
        assert!(matches!(
            events.last(),
            Some(NormalizedEvent::PlanCompleted { item_id, text })
                if item_id == "request-plan-plan"
                    && text == "- inspect final\n- implement final\n"
        ));
    }

    #[test]
    fn non_plan_mode_keeps_proposed_plan_markup_as_assistant_delta() {
        let raw = "<proposed_plan>\n- inspect\n</proposed_plan>";
        let mut parser = PlanTextNormalizer::new("request-default", false);
        let events = parser.push_str(raw);
        assert!(matches!(
            events.as_slice(),
            [NormalizedEvent::Delta(delta)] if delta == raw
        ));
        assert!(parser.complete_with_response_text(None).is_empty());
    }

    #[test]
    fn plan_mode_finish_closes_unterminated_plan_with_accumulated_text() {
        let mut parser = PlanTextNormalizer::new("request-unclosed", true);
        let mut events = parser.push_str("<proposed_plan>\n- inspect\n");
        events.extend(parser.complete_with_response_text(None));
        assert!(matches!(
            events.last(),
            Some(NormalizedEvent::PlanCompleted { item_id, text })
                if item_id == "request-unclosed-plan" && text == "- inspect\n"
        ));
    }

    #[test]
    fn plan_mode_final_only_item_emits_visible_text_and_plan_lifecycle() {
        let mut normalizer = ProviderStreamNormalizer::new("request-final-plan", true);
        let events = normalizer.normalize(ResponseEvent::OutputItemDone(assistant_item(
            "Preface\n<proposed_plan>\n- inspect\n</proposed_plan>\nPostscript",
        )));

        assert!(matches!(
            events.first(),
            Some(NormalizedEvent::Delta(delta)) if delta == "Preface\n"
        ));
        assert!(events.iter().any(|event| matches!(
            event,
            NormalizedEvent::PlanStarted { item_id }
                if item_id == "request-final-plan-plan"
        )));
        assert!(events.iter().any(|event| matches!(
            event,
            NormalizedEvent::PlanDelta { item_id, delta }
                if item_id == "request-final-plan-plan" && delta == "- inspect\n"
        )));
        assert!(events.iter().any(|event| matches!(
            event,
            NormalizedEvent::PlanCompleted { item_id, text }
                if item_id == "request-final-plan-plan" && text == "- inspect\n"
        )));
        assert!(events.iter().any(|event| matches!(
            event,
            NormalizedEvent::Delta(delta) if delta == "Postscript"
        )));
        assert!(matches!(
            events.last(),
            Some(NormalizedEvent::ResponseItem(_))
        ));
    }

    #[test]
    fn non_plan_mode_final_only_item_emits_assistant_text_once() {
        let mut normalizer = ProviderStreamNormalizer::new("request-final-default", false);
        let events = normalizer.normalize(ResponseEvent::OutputItemDone(assistant_item("Done")));
        assert!(matches!(
            events.as_slice(),
            [NormalizedEvent::Delta(delta), NormalizedEvent::ResponseItem(_)]
                if delta == "Done"
        ));

        let mut streamed = ProviderStreamNormalizer::new("request-streamed-default", false);
        let mut replayed = streamed.normalize(ResponseEvent::OutputTextDelta("Done".to_string()));
        replayed.extend(streamed.normalize(ResponseEvent::OutputItemDone(assistant_item("Done"))));
        assert_eq!(
            replayed
                .iter()
                .filter(|event| matches!(event, NormalizedEvent::Delta(_)))
                .count(),
            1
        );
    }

    #[test]
    fn plan_mode_wire_events_preserve_exact_fields_and_sequence() {
        let mut encoder = ProviderEventEncoder::new("request-plan-wire", 41);
        let started: serde_json::Value = serde_json::from_slice(
            &encoder
                .normalized(NormalizedEvent::PlanStarted {
                    item_id: "request-plan-wire-plan".to_string(),
                })
                .expect("encode plan start"),
        )
        .expect("decode plan start");
        let delta: serde_json::Value = serde_json::from_slice(
            &encoder
                .normalized(NormalizedEvent::PlanDelta {
                    item_id: "request-plan-wire-plan".to_string(),
                    delta: "- inspect\n".to_string(),
                })
                .expect("encode plan delta"),
        )
        .expect("decode plan delta");
        let completed: serde_json::Value = serde_json::from_slice(
            &encoder
                .normalized(NormalizedEvent::PlanCompleted {
                    item_id: "request-plan-wire-plan".to_string(),
                    text: "- inspect final\n".to_string(),
                })
                .expect("encode plan completion"),
        )
        .expect("decode plan completion");

        assert_eq!(
            started,
            json!({
                "sequence": 41,
                "kind": "planStarted",
                "requestId": "request-plan-wire",
                "itemId": "request-plan-wire-plan"
            })
        );
        assert_eq!(
            delta,
            json!({
                "sequence": 42,
                "kind": "planDelta",
                "requestId": "request-plan-wire",
                "itemId": "request-plan-wire-plan",
                "delta": "- inspect\n"
            })
        );
        assert_eq!(
            completed,
            json!({
                "sequence": 43,
                "kind": "planCompleted",
                "requestId": "request-plan-wire",
                "itemId": "request-plan-wire-plan",
                "text": "- inspect final\n"
            })
        );
        assert_eq!(encoder.emitted_count(), 3);
    }

    #[test]
    fn request_body_matches_official_responses_shape() {
        let body = response_body(&request());
        assert_eq!(body["model"], "gpt-test");
        assert_eq!(body["reasoning"]["effort"], "high");
        assert_eq!(body["stream"], true);
        assert_eq!(body["store"], false);
        assert_eq!(body["include"], json!(["reasoning.encrypted_content"]));
        assert_eq!(body["input"][0]["type"], "message");
        assert_eq!(body["input"][0]["content"][0]["type"], "input_text");
        assert_eq!(
            body["input"][0]["content"][0]["text"],
            "Inspect this project."
        );
        assert_eq!(body["tools"], json!([]));
    }

    #[test]
    fn chatgpt_request_body_normalizes_released_renderer_model_alias() {
        let mut request = request();
        request.model = "gpt-5-6".to_string();

        let body = response_body(&request);

        assert_eq!(body["model"], "gpt-5.5");
    }

    #[test]
    fn chatgpt_request_body_falls_back_from_catalog_default_model() {
        let mut request = request();
        request.model = "gpt-5.6-sol".to_string();

        let body = response_body(&request);

        assert_eq!(body["model"], "gpt-5.5");
    }

    #[test]
    fn openai_api_request_body_normalizes_released_renderer_model_alias() {
        let mut request = request();
        request.base_url = Some("https://api.openai.com/v1".to_string());
        request.model = "gpt-5-6".to_string();

        let body = response_body(&request);

        assert_eq!(body["model"], "gpt-5.6-sol");
    }

    #[test]
    fn custom_provider_request_body_preserves_provider_model_name() {
        let mut request = request();
        request.base_url = Some("https://provider.example/v1".to_string());
        request.model = "gpt-5-6".to_string();

        let body = response_body(&request);

        assert_eq!(body["model"], "gpt-5-6");
    }

    #[test]
    fn request_body_preserves_text_elements_for_official_provider() {
        let request = request_from_json(json!({
            "input": [{
                "type": "text",
                "text": "Open @main.swift",
                "text_elements": [{
                    "byteRange": {"start": 5, "end": 16},
                    "placeholder": "@main.swift"
                }]
            }]
        }));

        let body = response_body(&request);
        assert_eq!(
            body["input"][0]["content"][0]["text_elements"],
            json!([{
                "byteRange": {"start": 5, "end": 16},
                "placeholder": "@main.swift"
            }])
        );
    }

    #[test]
    fn mcp_and_tool_search_specs_match_official_26_727_40816() {
        let request = request_from_json(json!({
            "mcpResourceTools": true,
            "toolSearchSources": [
                {"name": "docs"},
                {
                    "name": "Google Drive",
                    "description": "Use Google Drive as the single entrypoint for Drive, Docs, Sheets, and Slides work."
                },
                {"name": "Google Drive"}
            ]
        }));
        let body = response_body(&request);

        assert_eq!(
            body["tools"][0],
            json!({
                "type": "function",
                "name": "list_mcp_resources",
                "description": "Lists resources provided by MCP servers. Resources allow servers to share data that provides context to language models, such as files, database schemas, or application-specific information. Prefer resources over web search when possible.",
                "strict": false,
                "parameters": {
                    "type": "object",
                    "properties": {
                        "server": {
                            "type": "string",
                            "description": "MCP server name. Omit to list resources from every configured server."
                        },
                        "cursor": {
                            "type": "string",
                            "description": "Opaque cursor from a previous list_mcp_resources call; omit for the first page."
                        }
                    },
                    "additionalProperties": false
                }
            })
        );
        assert_eq!(
            body["tools"][1],
            json!({
                "type": "function",
                "name": "list_mcp_resource_templates",
                "description": "Lists resource templates provided by MCP servers. Parameterized resource templates allow servers to share data that takes parameters and provides context to language models, such as files, database schemas, or application-specific information. Prefer resource templates over web search when possible.",
                "strict": false,
                "parameters": {
                    "type": "object",
                    "properties": {
                        "server": {
                            "type": "string",
                            "description": "MCP server name. Omit to list resource templates from every configured server."
                        },
                        "cursor": {
                            "type": "string",
                            "description": "Opaque cursor from a previous list_mcp_resource_templates call; omit for the first page."
                        }
                    },
                    "additionalProperties": false
                }
            })
        );
        assert_eq!(
            body["tools"][2],
            json!({
                "type": "function",
                "name": "read_mcp_resource",
                "description": "Read a specific resource from an MCP server given the server name and resource URI.",
                "strict": false,
                "parameters": {
                    "type": "object",
                    "properties": {
                        "server": {
                            "type": "string",
                            "description": "MCP server name exactly as configured. Must match the 'server' field returned by list_mcp_resources."
                        },
                        "uri": {
                            "type": "string",
                            "description": "Resource URI to read. Must be one of the URIs returned by list_mcp_resources."
                        }
                    },
                    "required": ["server", "uri"],
                    "additionalProperties": false
                }
            })
        );
        assert_eq!(
            body["tools"][3],
            json!({
                "type": "tool_search",
                "execution": "client",
                "description": concat!(
                    "# Tool discovery\n\n",
                    "Searches over deferred tool metadata with BM25 and exposes matching tools for the next model call.\n\n",
                    "You have access to tools from the following sources:\n",
                    "- Google Drive: Use Google Drive as the single entrypoint for Drive, Docs, Sheets, and Slides work.\n",
                    "- docs\n",
                    "Some of the tools may not have been provided to you upfront, and you should use this tool (`tool_search`) to search for the required tools. For MCP tool discovery, always use `tool_search` instead of `list_mcp_resources` or `list_mcp_resource_templates`."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "query": {
                            "type": "string",
                            "description": "Search query for deferred tools."
                        },
                        "limit": {
                            "type": "number",
                            "description": "Maximum number of tools to return. Defaults to 8."
                        }
                    },
                    "required": ["query"],
                    "additionalProperties": false
                }
            })
        );
        assert_eq!(body["tools"].as_array().map(Vec::len), Some(4));
    }

    #[test]
    fn mcp_and_tool_search_registration_follows_official_conditions_and_order() {
        let default_body = response_body(&request_from_json(json!({})));
        assert_eq!(default_body["tools"], json!([]));

        let empty_sources = response_body(&request_from_json(json!({
            "mcpResourceTools": true,
            "toolSearchSources": []
        })));
        assert_eq!(
            empty_sources["tools"]
                .as_array()
                .expect("tools")
                .iter()
                .map(|tool| tool["name"].as_str().unwrap_or_default())
                .collect::<Vec<_>>(),
            vec![
                "list_mcp_resources",
                "list_mcp_resource_templates",
                "read_mcp_resource"
            ]
        );

        let search_only = response_body(&request_from_json(json!({
            "toolSearchSources": [{"name": "docs"}]
        })));
        assert_eq!(search_only["tools"].as_array().map(Vec::len), Some(1));
        assert_eq!(search_only["tools"][0]["type"], "tool_search");

        let ordered = response_body(&request_from_json(json!({
            "workspaceTools": true,
            "requestUserInputTool": true,
            "updatePlanTool": true,
            "viewImageTool": true,
            "mcpResourceTools": true,
            "toolSearchSources": [{"name": "docs"}]
        })));
        assert_eq!(
            ordered["tools"]
                .as_array()
                .expect("tools")
                .iter()
                .map(|tool| {
                    tool["name"]
                        .as_str()
                        .unwrap_or_else(|| tool["type"].as_str().expect("tool type"))
                })
                .collect::<Vec<_>>(),
            vec![
                "list_workspace_files",
                "read_workspace_file",
                "search_workspace_text",
                "write_workspace_file",
                "exec_command",
                "write_stdin",
                "apply_patch",
                "list_mcp_resources",
                "list_mcp_resource_templates",
                "read_mcp_resource",
                "request_user_input",
                "update_plan",
                "view_image",
                "tool_search"
            ]
        );
    }

    #[test]
    fn dynamic_tools_are_normalized_and_registered_in_declared_order() {
        let canonical = response_body(&request_from_json(json!({
            "dynamicTools": [
                {
                    "type": "function",
                    "name": "lookup_ticket",
                    "description": "Look up a ticket.",
                    "inputSchema": {
                        "type": "object",
                        "properties": {"id": {"type": "string"}},
                        "required": ["id"],
                        "additionalProperties": false
                    }
                },
                {
                    "type": "namespace",
                    "name": "calendar",
                    "description": "Calendar tools.",
                    "tools": [{
                        "type": "function",
                        "name": "create_event",
                        "description": "Create an event.",
                        "inputSchema": {"type": "object", "properties": {}}
                    }]
                }
            ]
        })));
        assert_eq!(
            canonical["tools"],
            json!([
                {
                    "type": "function",
                    "name": "lookup_ticket",
                    "description": "Look up a ticket.",
                    "strict": false,
                    "parameters": {
                        "type": "object",
                        "properties": {"id": {"type": "string"}},
                        "required": ["id"],
                        "additionalProperties": false
                    }
                },
                {
                    "type": "namespace",
                    "name": "calendar",
                    "description": "Calendar tools.",
                    "tools": [{
                        "type": "function",
                        "name": "create_event",
                        "description": "Create an event.",
                        "strict": false,
                        "parameters": {"type": "object", "properties": {}}
                    }]
                }
            ])
        );

        let legacy = response_body(&request_from_json(json!({
            "dynamicTools": [{
                "namespace": "tickets",
                "name": "lookup",
                "description": "Look up a ticket.",
                "inputSchema": {"type": "object", "properties": {}},
                "exposeToContext": true
            }]
        })));
        assert_eq!(legacy["tools"][0]["type"], "namespace");
        assert_eq!(legacy["tools"][0]["name"], "tickets");
        assert_eq!(legacy["tools"][0]["tools"][0]["name"], "lookup");
    }

    #[test]
    fn workspace_tools_and_results_match_responses_contract() {
        let mut request = request();
        request.workspace_tools = true;
        request.input_history.push(
            r#"{"type":"function_call","name":"read_workspace_file","arguments":"{\"path\":\"README.md\"}","call_id":"call-1"}"#.to_string(),
        );
        request.input_history.push(
            r#"{"type":"function_call_output","call_id":"call-1","output":"{\"text\":\"hello\"}"}"#
                .to_string(),
        );
        let body = response_body(&request);
        assert_eq!(body["tools"].as_array().map(Vec::len), Some(7));
        assert_eq!(body["tools"][2]["name"], "search_workspace_text");
        assert_eq!(body["tools"][4]["name"], "exec_command");
        assert_eq!(body["tools"][5]["name"], "write_stdin");
        assert_eq!(body["tools"][6]["type"], "custom");
        assert_eq!(body["tools"][6]["name"], "apply_patch");
        assert_eq!(
            body["tools"][6]["description"],
            "The `apply_patch` tool can be used to edit files. This is a FREEFORM tool, so do not wrap the patch in JSON."
        );
        assert_eq!(body["tools"][6]["format"]["type"], "grammar");
        assert_eq!(body["tools"][6]["format"]["syntax"], "lark");
        assert_eq!(
            body["tools"][6]["format"]["definition"],
            concat!(
                "start: begin_patch hunk+ end_patch\n",
                "begin_patch: \"*** Begin Patch\" LF\n",
                "end_patch: \"*** End Patch\" LF?\n",
                "\n",
                "hunk: add_hunk | delete_hunk | update_hunk\n",
                "add_hunk: \"*** Add File: \" filename LF add_line+\n",
                "delete_hunk: \"*** Delete File: \" filename LF\n",
                "update_hunk: \"*** Update File: \" filename LF change_move? change?\n",
                "\n",
                "filename: /(.+)/\n",
                "add_line: \"+\" /(.*)/ LF -> line\n",
                "\n",
                "change_move: \"*** Move to: \" filename LF\n",
                "change: (change_context | change_line)+ eof_line?\n",
                "change_context: (\"@@\" | \"@@ \" /(.+)/) LF\n",
                "change_line: (\"+\" | \"-\" | \" \") /(.*)/ LF\n",
                "eof_line: \"*** End of File\" LF\n",
                "\n",
                "%import common.LF\n",
            )
        );
        assert_eq!(body["input"][1]["type"], "function_call");
        assert_eq!(body["input"][1]["call_id"], "call-1");
        assert_eq!(body["input"][2]["type"], "function_call_output");
        assert_eq!(body["input"][2]["output"], r#"{"text":"hello"}"#);
    }

    #[test]
    fn exec_command_matches_official_26_727_40816_schema() {
        let mut request = request();
        request.workspace_tools = true;

        let body = response_body(&request);
        let tool = &body["tools"][4];

        assert_eq!(tool["type"], "function");
        assert_eq!(tool["name"], "exec_command");
        assert_eq!(
            tool["description"],
            "Runs a command in a PTY, returning output or a session ID for ongoing interaction."
        );
        assert_eq!(tool["strict"], false);
        assert_eq!(
            tool["parameters"],
            json!({
                "type": "object",
                "properties": {
                    "cmd": {
                        "type": "string",
                        "description": "Shell command to execute."
                    },
                    "workdir": {
                        "type": "string",
                        "description": "Working directory for the command. Defaults to the turn cwd."
                    },
                    "tty": {
                        "type": "boolean",
                        "description": "True allocates a PTY for the command; false or omitted uses plain pipes."
                    },
                    "yield_time_ms": {
                        "type": "number",
                        "description": "Wait before yielding output. Defaults to 10000 ms; effective range is 250-30000 ms."
                    },
                    "max_output_tokens": {
                        "type": "number",
                        "description": "Output token budget. Defaults to 10000 tokens; larger requests may be capped by policy."
                    },
                    "shell": {
                        "type": "string",
                        "description": "Shell binary to launch. Defaults to the user's default shell."
                    },
                    "login": {
                        "type": "boolean",
                        "description": "True runs the shell with -l/-i semantics; false disables them. Defaults to true."
                    }
                },
                "required": ["cmd"],
                "additionalProperties": false
            })
        );
        assert_eq!(tool["output_schema"], expected_unified_exec_output_schema());
    }

    #[test]
    fn write_stdin_matches_official_26_727_40816_schema() {
        let mut request = request();
        request.workspace_tools = true;

        let body = response_body(&request);
        let tool = &body["tools"][5];

        assert_eq!(tool["type"], "function");
        assert_eq!(tool["name"], "write_stdin");
        assert_eq!(
            tool["description"],
            "Writes characters to an existing unified exec session and returns recent output."
        );
        assert_eq!(tool["strict"], false);
        assert_eq!(
            tool["parameters"],
            json!({
                "type": "object",
                "properties": {
                    "session_id": {
                        "type": "number",
                        "description": "Identifier of the running unified exec session."
                    },
                    "chars": {
                        "type": "string",
                        "description": "Bytes to write to stdin. Defaults to empty, which polls without writing."
                    },
                    "yield_time_ms": {
                        "type": "number",
                        "description": "Wait before yielding output. Non-empty writes default to 250 ms and cap at 30000 ms; empty polls wait 5000-300000 ms by default."
                    },
                    "max_output_tokens": {
                        "type": "number",
                        "description": "Output token budget. Defaults to 10000 tokens; larger requests may be capped by policy."
                    }
                },
                "required": ["session_id"],
                "additionalProperties": false
            })
        );
        assert_eq!(tool["output_schema"], expected_unified_exec_output_schema());
    }

    #[test]
    fn request_user_input_tool_is_independent_and_matches_official_schema() {
        let mut request = request();
        request.workspace_tools = false;
        request.request_user_input_tool = true;

        let body = response_body(&request);
        let tools = body["tools"].as_array().expect("responses tools array");

        assert_eq!(tools.len(), 1);
        let tool = &tools[0];
        assert_eq!(tool["type"], "function");
        assert_eq!(tool["name"], "request_user_input");
        assert_eq!(tool["strict"], false);
        assert_eq!(
            tool["description"],
            "Request user input for one to three short questions and wait for the response. Set autoResolutionMs, from 60000 to 240000 milliseconds, only when the question is useful but non-blocking and continuing with best judgment is acceptable if the user does not answer; omit it when explicit user input is required."
        );
        assert_eq!(tool["parameters"]["type"], "object");
        assert_eq!(tool["parameters"]["required"], json!(["questions"]));
        assert_eq!(tool["parameters"]["additionalProperties"], false);
        assert_eq!(
            tool["parameters"]["properties"]["questions"]["description"],
            "Questions to show the user. Prefer 1 and do not exceed 3"
        );
        let question = &tool["parameters"]["properties"]["questions"]["items"];
        assert_eq!(question["type"], "object");
        assert_eq!(
            question["required"],
            json!(["id", "header", "question", "options"])
        );
        assert_eq!(question["additionalProperties"], false);
        assert_eq!(
            question["properties"]["id"]["description"],
            "Stable identifier for mapping answers (snake_case)."
        );
        assert_eq!(
            question["properties"]["header"]["description"],
            "Short header label shown in the UI (12 or fewer chars)."
        );
        assert_eq!(
            question["properties"]["question"]["description"],
            "Single-sentence prompt shown to the user."
        );
        let options = &question["properties"]["options"];
        assert_eq!(
            options["description"],
            "Provide 2-3 mutually exclusive choices. Put the recommended option first and suffix its label with \"(Recommended)\". Do not include an \"Other\" option in this list; the client will add a free-form \"Other\" option automatically."
        );
        assert_eq!(options["items"]["type"], "object");
        assert_eq!(
            options["items"]["required"],
            json!(["label", "description"])
        );
        assert_eq!(options["items"]["additionalProperties"], false);
        assert_eq!(
            options["items"]["properties"]["label"]["description"],
            "User-facing label (1-5 words)."
        );
        assert_eq!(
            options["items"]["properties"]["description"]["description"],
            "One short sentence explaining impact/tradeoff if selected."
        );
        assert_eq!(
            tool["parameters"]["properties"]["autoResolutionMs"]["type"],
            "number"
        );
        assert_eq!(
            tool["parameters"]["properties"]["autoResolutionMs"]["description"],
            "Optional auto-resolution window in milliseconds, from 60000 to 240000. Include this only when the question is useful but non-blocking and continuing with best judgment is acceptable if the user does not answer; omit it when explicit user input is required before continuing. Use 60000 for lightly helpful context and up to 240000 when the answer would materially unblock better work."
        );
    }

    #[test]
    fn request_permissions_tool_is_independent_and_matches_official_schema() {
        let mut request = request();
        request.workspace_tools = false;
        request.request_permissions_tool = true;

        let body = response_body(&request);
        let tools = body["tools"].as_array().expect("responses tools array");

        assert_eq!(tools.len(), 1);
        let tool = &tools[0];
        assert_eq!(tool["type"], "function");
        assert_eq!(tool["name"], "request_permissions");
        assert_eq!(tool["strict"], false);
        assert_eq!(
            tool["description"],
            "Request additional filesystem or network permissions from the user and wait for the client to grant a subset of the requested permission profile. Use environment_id to target a specific attached environment; omit it to use the primary environment. Relative filesystem paths resolve against the selected environment cwd. Granted permissions apply automatically to later shell-like commands in the current turn, or for the rest of the session if the client approves them at session scope."
        );
        assert_eq!(tool["parameters"]["required"], json!(["permissions"]));
        assert_eq!(tool["parameters"]["additionalProperties"], false);
        let permissions = &tool["parameters"]["properties"]["permissions"];
        assert_eq!(permissions["type"], "object");
        assert_eq!(permissions["additionalProperties"], false);
        assert_eq!(
            permissions["properties"]["network"]["properties"]["enabled"]["type"],
            "boolean"
        );
        assert_eq!(
            permissions["properties"]["file_system"]["properties"]["read"]["items"]["type"],
            "string"
        );
        assert_eq!(
            permissions["properties"]["file_system"]["properties"]["write"]["items"]["type"],
            "string"
        );
    }

    #[test]
    fn update_plan_tool_is_independent_and_matches_official_schema() {
        let mut request = request();
        request.workspace_tools = false;
        request.update_plan_tool = true;

        let body = response_body(&request);
        let tools = body["tools"].as_array().expect("responses tools array");

        assert_eq!(tools.len(), 1);
        let tool = &tools[0];
        assert_eq!(tool["type"], "function");
        assert_eq!(tool["name"], "update_plan");
        assert_eq!(tool["strict"], false);
        assert_eq!(
            tool["description"],
            "Updates the task plan.\nProvide an optional explanation and a list of plan items, each with a step and status.\nAt most one step can be in_progress at a time.\n"
        );
        assert_eq!(tool["parameters"]["type"], "object");
        assert_eq!(tool["parameters"]["required"], json!(["plan"]));
        assert_eq!(tool["parameters"]["additionalProperties"], false);
        assert_eq!(
            tool["parameters"]["properties"]["explanation"]["description"],
            "Optional explanation for this plan update."
        );
        let plan = &tool["parameters"]["properties"]["plan"];
        assert_eq!(plan["type"], "array");
        assert_eq!(plan["description"], "The list of steps");
        assert_eq!(plan["items"]["type"], "object");
        assert_eq!(plan["items"]["required"], json!(["step", "status"]));
        assert_eq!(plan["items"]["additionalProperties"], false);
        assert_eq!(
            plan["items"]["properties"]["step"]["description"],
            "Task step text."
        );
        assert_eq!(
            plan["items"]["properties"]["status"]["enum"],
            json!(["pending", "in_progress", "completed"])
        );
        assert_eq!(
            plan["items"]["properties"]["status"]["description"],
            "Step status."
        );
    }

    #[test]
    fn view_image_tool_is_independent_and_matches_official_schema() {
        let mut request = request();
        request.workspace_tools = false;
        request.view_image_tool = true;

        let body = response_body(&request);
        let tools = body["tools"].as_array().expect("responses tools array");

        assert_eq!(tools.len(), 1);
        let tool = &tools[0];
        assert_eq!(tool["type"], "function");
        assert_eq!(tool["name"], "view_image");
        assert_eq!(tool["strict"], false);
        assert_eq!(
            tool["description"],
            "View a local image file from the filesystem when visual inspection is needed. Use this for images already available on disk."
        );
        assert_eq!(tool["parameters"]["type"], "object");
        assert_eq!(tool["parameters"]["required"], json!(["path"]));
        assert_eq!(tool["parameters"]["additionalProperties"], false);
        assert_eq!(
            tool["parameters"]["properties"]["path"]["description"],
            "Local filesystem path to an image file."
        );
        assert_eq!(
            tool["parameters"]["properties"]["detail"]["enum"],
            json!(["high", "original"])
        );
        assert_eq!(
            tool["parameters"]["properties"]["detail"]["description"],
            "Image detail level. Defaults to `high`; use `original` to preserve exact resolution."
        );
        assert_eq!(tool["output_schema"]["type"], "object");
        assert_eq!(
            tool["output_schema"]["required"],
            json!(["image_url", "detail"])
        );
        assert_eq!(tool["output_schema"]["additionalProperties"], false);
        assert_eq!(
            tool["output_schema"]["properties"]["image_url"]["description"],
            "Data URL for the loaded image."
        );
        assert_eq!(
            tool["output_schema"]["properties"]["detail"]["enum"],
            json!(["high", "original"])
        );
    }

    #[test]
    fn enabling_request_user_input_preserves_apply_patch_as_seventh_workspace_tool() {
        let mut request = request();
        request.workspace_tools = true;
        request.request_user_input_tool = true;

        let body = response_body(&request);

        assert_eq!(body["tools"].as_array().map(Vec::len), Some(8));
        assert_eq!(body["tools"][6]["type"], "custom");
        assert_eq!(body["tools"][6]["name"], "apply_patch");
        assert_eq!(body["tools"][6]["format"]["type"], "grammar");
        assert_eq!(body["tools"][6]["format"]["syntax"], "lark");
        assert_eq!(
            body["tools"][6]["format"]["definition"],
            APPLY_PATCH_LARK_GRAMMAR
        );
        assert_eq!(body["tools"][7]["name"], "request_user_input");
    }

    #[test]
    fn resumed_history_precedes_new_user_input_and_same_turn_history_follows_it() {
        let mut request = request();
        request.prior_input_items.push(
            r#"{"type":"message","role":"user","content":[{"type":"input_text","text":"Earlier question"}]}"#
                .to_string(),
        );
        request.prior_input_items.push(
            r#"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Earlier answer"}]}"#
                .to_string(),
        );
        request.input_history.push(
            r#"{"type":"function_call","name":"read_workspace_file","arguments":"{\"path\":\"README.md\"}","call_id":"call-1"}"#.to_string(),
        );

        let body = response_body(&request);
        let input = body["input"].as_array().expect("responses input array");

        assert_eq!(input[0]["role"], "user");
        assert_eq!(input[0]["content"][0]["text"], "Earlier question");
        assert_eq!(input[1]["role"], "assistant");
        assert_eq!(input[1]["content"][0]["text"], "Earlier answer");
        assert_eq!(input[2]["role"], "user");
        assert_eq!(input[2]["content"][0]["text"], "Inspect this project.");
        assert_eq!(input[3]["type"], "function_call");
        assert_eq!(input[3]["call_id"], "call-1");
    }

    #[test]
    fn malformed_resumed_history_is_rejected_before_provider_transport() {
        let mut request = request();
        request.prior_input_items.push("{not-json".to_string());

        assert_eq!(validate_request(&request), Err(CoreError::InvalidArgument));
    }

    fn assert_history_item_validation(item: &str, expected: Result<(), CoreError>) {
        let mut prior_request = request();
        prior_request.prior_input_items.push(item.to_string());
        assert_eq!(
            validate_request(&prior_request),
            expected,
            "priorInputItems accepted an invalid item or rejected a valid one: {item}"
        );

        let mut same_turn_request = request();
        same_turn_request.input_history.push(item.to_string());
        assert_eq!(
            validate_request(&same_turn_request),
            expected,
            "inputHistory accepted an invalid item or rejected a valid one: {item}"
        );
    }

    #[test]
    fn response_history_rejects_non_item_json_values_in_both_channels() {
        for item in ["null", "true", "42", r#""text""#, "[]", "{}"] {
            assert_history_item_validation(item, Err(CoreError::InvalidArgument));
        }
    }

    #[test]
    fn response_history_rejects_unknown_or_incomplete_items_in_both_channels() {
        for item in [
            r#"{"type":"future_response_item","payload":{}}"#,
            r#"{"type":"message","content":[]}"#,
            r#"{"type":"message","role":"user"}"#,
            r#"{"type":"message","role":"user","content":[{"type":"input_text"}]}"#,
            r#"{"type":"function_call","arguments":"{}","call_id":"call-1"}"#,
            r#"{"type":"function_call","name":"tool","call_id":"call-1"}"#,
            r#"{"type":"function_call","name":"tool","arguments":"{}"}"#,
            r#"{"type":"function_call_output","call_id":"call-1"}"#,
            r#"{"type":"function_call_output","output":"done"}"#,
        ] {
            assert_history_item_validation(item, Err(CoreError::InvalidArgument));
        }
    }

    #[test]
    fn response_history_accepts_pinned_official_item_variants() {
        for item in [
            r#"{"type":"additional_tools","role":"assistant","tools":[]}"#,
            r#"{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}"#,
            r#"{"type":"agent_message","author":"agent-a","recipient":"agent-b","content":[{"type":"input_text","text":"hello"}]}"#,
            r#"{"type":"reasoning","summary":[{"type":"summary_text","text":"summary"}],"encrypted_content":null}"#,
            r#"{"type":"local_shell_call","call_id":"call-1","status":"completed","action":{"type":"exec","command":["pwd"],"timeout_ms":null,"working_directory":null,"env":null,"user":null}}"#,
            r#"{"type":"function_call","name":"tool","arguments":"{}","call_id":"call-1"}"#,
            r#"{"type":"tool_search_call","call_id":null,"execution":"search","arguments":{}}"#,
            r#"{"type":"function_call_output","call_id":"call-1","output":"done"}"#,
            r#"{"type":"custom_tool_call","call_id":"call-1","name":"tool","input":"payload"}"#,
            r#"{"type":"custom_tool_call_output","call_id":"call-1","output":"done"}"#,
            r#"{"type":"tool_search_output","call_id":null,"status":"completed","execution":"search","tools":[]}"#,
            r#"{"type":"web_search_call"}"#,
            r#"{"type":"image_generation_call","status":"completed","result":"image-data"}"#,
            r#"{"type":"compaction","encrypted_content":"opaque"}"#,
            r#"{"type":"compaction_summary","encrypted_content":"opaque"}"#,
            r#"{"type":"compaction_trigger"}"#,
            r#"{"type":"context_compaction"}"#,
        ] {
            assert_history_item_validation(item, Ok(()));
        }
    }

    #[test]
    fn response_history_rejects_remote_images_in_official_item_locations() {
        for item in [
            r#"{"type":"message","role":"user","content":[{"type":"input_image","image_url":"http://example.test/image.png"}]}"#,
            r#"{"type":"function_call_output","call_id":"call-1","output":[{"type":"input_image","image_url":"https://example.test/image.png"}]}"#,
            r#"{"type":"custom_tool_call_output","call_id":"call-2","output":[{"type":"input_image","image_url":"HTTPS://example.test/image.png"}]}"#,
        ] {
            assert_history_item_validation(item, Err(CoreError::InvalidArgument));
        }
    }

    #[test]
    fn response_history_accepts_supported_image_urls_in_official_item_locations() {
        for item in [
            r#"{"type":"message","role":"user","content":[{"type":"input_image","image_url":"data:image/png;base64,AAAA"}]}"#,
            r#"{"type":"function_call_output","call_id":"call-1","output":[{"type":"input_image","image_url":"file:///tmp/image.png"}]}"#,
            r#"{"type":"custom_tool_call_output","call_id":"call-2","output":[{"type":"input_image","image_url":"/tmp/image.png"}]}"#,
        ] {
            assert_history_item_validation(item, Ok(()));
        }
    }

    #[test]
    fn typed_history_validation_preserves_original_json_values_and_channel_order() {
        let prior_item = r#"{"type":"message","role":"user","content":[{"type":"input_text","text":"Earlier"}],"provider_extension":{"trace":"prior"}}"#;
        let same_turn_item = r#"{"type":"function_call_output","call_id":"call-1","output":"done","provider_extension":{"trace":"same-turn"}}"#;
        let mut request = request();
        request.prior_input_items.push(prior_item.to_string());
        request.input_history.push(same_turn_item.to_string());

        assert_eq!(validate_request(&request), Ok(()));
        let body = response_body(&request);
        let input = body["input"].as_array().expect("responses input array");

        assert_eq!(input.len(), 3);
        assert_eq!(
            input[0],
            serde_json::from_str::<serde_json::Value>(prior_item).unwrap()
        );
        assert_eq!(input[1]["content"][0]["text"], "Inspect this project.");
        assert_eq!(
            input[2],
            serde_json::from_str::<serde_json::Value>(same_turn_item).unwrap()
        );
        assert_eq!(input[0]["provider_extension"]["trace"], "prior");
        assert_eq!(input[2]["provider_extension"]["trace"], "same-turn");
    }

    #[test]
    fn bearer_auth_matches_official_header_contract() {
        let auth = BearerAuth {
            token: "token".to_string(),
            account_id: Some("account".to_string()),
        };
        let mut headers = HeaderMap::new();
        auth.add_auth_headers(&mut headers);
        assert_eq!(
            headers
                .get(http::header::AUTHORIZATION)
                .and_then(|value| value.to_str().ok()),
            Some("Bearer token")
        );
        assert_eq!(
            headers
                .get("ChatGPT-Account-ID")
                .and_then(|value| value.to_str().ok()),
            Some("account")
        );
    }

    #[test]
    fn only_https_provider_urls_are_accepted() {
        let mut invalid = request();
        invalid.base_url = Some("http://example.test".to_string());
        assert_eq!(validate_request(&invalid), Err(CoreError::InvalidArgument));
        invalid.base_url = Some("https://example.test/".to_string());
        assert_eq!(validate_request(&invalid), Err(CoreError::InvalidArgument));
        invalid.base_url = Some("https://example.test".to_string());
        assert_eq!(validate_request(&invalid), Ok(()));
    }

    #[test]
    fn provider_proxy_accepts_only_credential_free_http_urls() {
        let mut candidate = request();
        candidate.proxy_url = Some("http://127.0.0.1:1082".to_string());
        assert_eq!(validate_request(&candidate), Ok(()));

        for invalid_proxy in [
            "socks5://127.0.0.1:1082",
            "http://user:secret@127.0.0.1:1082",
            "http://127.0.0.1:1082/path",
            "http://127.0.0.1:1082?token=secret",
        ] {
            candidate.proxy_url = Some(invalid_proxy.to_string());
            assert_eq!(
                validate_request(&candidate),
                Err(CoreError::InvalidArgument)
            );
        }
    }

    #[test]
    fn reasoning_effort_accepts_every_nonempty_model_catalog_value() {
        for effort in [
            "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra", "focused",
        ] {
            let mut candidate = request();
            candidate.reasoning_effort = effort.to_string();
            assert_eq!(validate_request(&candidate), Ok(()));
        }
        let mut invalid = request();
        invalid.reasoning_effort = "   ".to_string();
        assert_eq!(validate_request(&invalid), Err(CoreError::InvalidArgument));
    }

    #[test]
    fn normalized_stream_events_preserve_sequence_and_source_commit() {
        let events = encode_events(
            "request-1",
            vec![
                NormalizedEvent::Delta("hel".to_string()),
                NormalizedEvent::Delta("lo".to_string()),
                NormalizedEvent::Completed {
                    response_id: "response-1".to_string(),
                    usage: None,
                    end_turn: None,
                },
            ],
            8,
        )
        .unwrap();
        let decoded: Vec<serde_json::Value> = events
            .iter()
            .map(|event| serde_json::from_slice(event).unwrap())
            .collect();
        assert_eq!(decoded.len(), 4);
        assert_eq!(decoded[0]["sequence"], 8);
        assert_eq!(decoded[0]["sourceCommit"], OFFICIAL_SOURCE_COMMIT);
        assert_eq!(decoded[1]["kind"], "assistantTextDelta");
        assert_eq!(decoded[1]["delta"], "hel");
        assert_eq!(decoded[3]["sequence"], 11);
        assert_eq!(decoded[3]["responseId"], "response-1");
    }

    #[test]
    fn provider_stream_open_timeout_does_not_report_connected() {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("test runtime");
        let connected = std::cell::Cell::new(false);

        let result = runtime.block_on(open_provider_stream(
            futures::future::pending::<Result<(), ()>>(),
            Duration::from_millis(5),
            || {
                connected.set(true);
                Ok(())
            },
        ));

        assert!(matches!(result, Err(ProviderStreamOpenError::Timeout)));
        assert!(!connected.get());
    }

    #[test]
    fn provider_stream_open_reports_connected_only_after_headers_arrive() {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("test runtime");
        let connected = std::cell::Cell::new(false);

        let result = runtime.block_on(open_provider_stream(
            futures::future::ready(Ok::<_, ()>("connected-stream")),
            Duration::from_secs(1),
            || {
                connected.set(true);
                Ok(())
            },
        ));

        assert!(matches!(result, Ok("connected-stream")));
        assert!(connected.get());
    }

    #[test]
    fn response_headers_timeout_payload_identifies_transport_stage() {
        let payload = provider_transport_timeout_payload("response_headers");

        assert_eq!(
            payload["message"],
            "Official provider response headers timed out."
        );
        assert_eq!(payload["stage"], "response_headers");
        assert_eq!(payload["code"], "response_headers_timeout");
    }

    #[test]
    fn realtime_provider_events_are_preserved_with_typed_payloads() {
        let normalized = normalize_event(ResponseEvent::ReasoningSummaryDelta {
            delta: "checking".to_string(),
            summary_index: 2,
        })
        .expect("reasoning event");
        let mut encoder = ProviderEventEncoder::new("request-realtime", 60);
        let event: serde_json::Value =
            serde_json::from_slice(&encoder.normalized(normalized).unwrap()).unwrap();

        assert_eq!(event["kind"], "providerRealtimeEvent");
        assert_eq!(event["requestId"], "request-realtime");
        assert_eq!(event["eventType"], "reasoning_summary_delta");
        assert_eq!(event["payload"]["delta"], "checking");
        assert_eq!(event["payload"]["summary_index"], 2);
    }

    #[test]
    fn completed_provider_event_preserves_usage_and_end_turn() {
        let normalized = normalize_event(ResponseEvent::Completed {
            response_id: "response-usage".to_string(),
            token_usage: Some(codex_protocol::protocol::TokenUsage {
                total_tokens: 42,
                input_tokens: 20,
                cached_input_tokens: 3,
                cache_write_input_tokens: 4,
                output_tokens: 22,
                reasoning_output_tokens: 5,
                codex_rollout_budget_units: None,
            }),
            end_turn: Some(true),
        })
        .expect("completed event");
        let mut encoder = ProviderEventEncoder::new("request-usage", 70);
        let event: serde_json::Value =
            serde_json::from_slice(&encoder.normalized(normalized).unwrap()).unwrap();

        assert_eq!(event["responseId"], "response-usage");
        assert_eq!(event["usage"]["totalTokens"], 42);
        assert_eq!(event["usage"]["inputTokens"], 20);
        assert_eq!(event["usage"]["cachedInputTokens"], 3);
        assert_eq!(event["usage"]["cacheWriteInputTokens"], 4);
        assert_eq!(event["usage"]["outputTokens"], 22);
        assert_eq!(event["usage"]["reasoningOutputTokens"], 5);
        assert_eq!(event["endTurn"], true);
    }

    #[test]
    fn completed_provider_event_treats_omitted_end_turn_as_terminal() {
        let normalized = normalize_event(ResponseEvent::Completed {
            response_id: "response-terminal".to_string(),
            token_usage: None,
            end_turn: None,
        })
        .expect("completed event");
        let mut encoder = ProviderEventEncoder::new("request-terminal", 80);
        let event: serde_json::Value =
            serde_json::from_slice(&encoder.normalized(normalized).unwrap()).unwrap();

        assert_eq!(event["responseId"], "response-terminal");
        assert_eq!(event["endTurn"], true);
    }

    #[test]
    fn custom_tool_call_is_normalized_as_a_tool_request_with_freeform_input() {
        let item = ResponseItem::CustomToolCall {
            id: None,
            status: Some("completed".to_string()),
            call_id: "call-apply-patch".to_string(),
            name: "apply_patch".to_string(),
            namespace: None,
            input: "*** Begin Patch\n*** End Patch\n".to_string(),
            internal_chat_message_metadata_passthrough: None,
        };
        let normalized =
            normalize_event(ResponseEvent::OutputItemDone(item)).expect("custom tool call event");
        let mut encoder = ProviderEventEncoder::new("request-apply-patch", 90);
        let event: serde_json::Value =
            serde_json::from_slice(&encoder.normalized(normalized).unwrap()).unwrap();

        assert_eq!(event["kind"], "toolCallRequested");
        assert_eq!(event["name"], "apply_patch");
        assert_eq!(event["arguments"], "*** Begin Patch\n*** End Patch\n");
        assert_eq!(event["callId"], "call-apply-patch");
        let item: serde_json::Value =
            serde_json::from_str(event["itemJson"].as_str().unwrap()).unwrap();
        assert_eq!(item["type"], "custom_tool_call");
        assert_eq!(item["name"], "apply_patch");
        assert_eq!(item["input"], "*** Begin Patch\n*** End Patch\n");
    }

    #[test]
    fn provider_event_encoder_emits_each_delta_without_batching() {
        let mut encoder = ProviderEventEncoder::new("request-1", 40);
        let started: serde_json::Value =
            serde_json::from_slice(&encoder.started().unwrap()).unwrap();
        let first: serde_json::Value = serde_json::from_slice(
            &encoder
                .normalized(NormalizedEvent::Delta("hel".to_string()))
                .unwrap(),
        )
        .unwrap();
        let second: serde_json::Value = serde_json::from_slice(
            &encoder
                .normalized(NormalizedEvent::Delta("lo".to_string()))
                .unwrap(),
        )
        .unwrap();

        assert_eq!(started["sequence"], 40);
        assert_eq!(first["sequence"], 41);
        assert_eq!(first["delta"], "hel");
        assert_eq!(second["sequence"], 42);
        assert_eq!(second["delta"], "lo");
        assert_eq!(encoder.emitted_count(), 3);
    }

    #[test]
    fn callback_rejection_stops_provider_delivery_as_cancelled() {
        let mut received = 0;
        let result = emit_if_continuing(
            &mut |_| {
                received += 1;
                false
            },
            b"event".to_vec(),
        );

        assert_eq!(result, Err(CoreError::Cancelled));
        assert_eq!(received, 1);
    }

    #[test]
    fn native_stream_prepares_the_canonical_authenticated_request() {
        let (prepared, mut stream) = start_native_stream(request(), 120, |_| true)
            .expect("native stream should expose the canonical request");

        assert_eq!(prepared.method, "POST");
        assert_eq!(
            prepared.url,
            "https://chatgpt.com/backend-api/codex/responses"
        );
        assert_eq!(
            prepared.header("authorization"),
            Some("Bearer secret-in-memory-only")
        );
        assert_eq!(prepared.header("chatgpt-account-id"), Some("account-1"));
        assert_eq!(prepared.header("accept"), Some("text/event-stream"));
        assert_eq!(prepared.header("originator"), Some("codex_cli_rs"));
        assert_eq!(prepared.header("content-type"), Some("application/json"));
        let body: serde_json::Value =
            serde_json::from_slice(&prepared.body).expect("canonical JSON body");
        assert_eq!(body, response_body(&request()));

        stream.cancel();
        let completion = stream.finish();
        assert_eq!(completion.result, Err(CoreError::Cancelled));
        assert_eq!(completion.emitted_count, 1);
    }

    #[test]
    fn native_stream_uses_the_upstream_sse_parser_and_existing_normalizer() {
        let received = Arc::new(std::sync::Mutex::new(Vec::new()));
        let captured = Arc::clone(&received);
        let (_prepared, mut stream) = start_native_stream(request(), 200, move |event| {
            captured.lock().expect("event lock").push(event);
            true
        })
        .expect("native stream should start");

        stream
            .begin_response(200, Vec::new())
            .expect("response head should be accepted");
        stream
            .push_body(
                br#"data: {"type":"response.created","response":{}}

data: {"type":"response.output_text.delta","delta":"hello"}

data: {"type":"response.completed","response":{"id":"response-native","usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2},"end_turn":true}}

"#,
            )
            .expect("SSE bytes should be accepted");
        stream.end_body().expect("body should close");
        let completion = stream.finish();
        assert_eq!(completion.result, Ok(()));

        let events = received.lock().expect("event lock");
        assert_eq!(
            completion.emitted_count as usize,
            events.iter().filter(|event| !event.is_empty()).count()
        );
        let decoded: Vec<serde_json::Value> = events
            .iter()
            .filter(|event| !event.is_empty())
            .map(|event| serde_json::from_slice(event).expect("provider event JSON"))
            .collect();
        assert_eq!(decoded[0]["kind"], "providerResponseStarted");
        assert_eq!(decoded[0]["sequence"], 200);
        assert!(
            decoded.iter().any(|event| {
                event["kind"] == "assistantTextDelta" && event["delta"] == "hello"
            })
        );
        assert!(decoded.iter().any(|event| {
            event["kind"] == "providerResponseCompleted" && event["responseId"] == "response-native"
        }));
    }
}
