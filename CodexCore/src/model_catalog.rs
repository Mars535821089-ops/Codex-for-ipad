use crate::CoreError;
use reqwest::header;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::fmt;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const DEFAULT_BASE_URL: &str = "https://chatgpt.com/backend-api/codex";
const CLIENT_VERSION: &str = include_str!("../resources/client-version.txt");

fn client_version() -> &'static str {
    CLIENT_VERSION.trim()
}

fn client_version_whole() -> String {
    client_version()
        .split('-')
        .next()
        .unwrap_or_default()
        .to_string()
}
const CACHE_TTL_MS: u64 = 300_000;
const CACHE_SCHEMA_VERSION: u32 = 1;

#[derive(Clone, Deserialize, Serialize)]
struct ModelsResponse {
    models: Vec<ModelInfo>,
}

#[derive(Clone, Deserialize, Serialize)]
struct ModelInfo {
    slug: String,
    display_name: String,
    #[serde(default)]
    description: Option<String>,
    #[serde(default)]
    default_reasoning_level: Option<String>,
    supported_reasoning_levels: Vec<ReasoningLevel>,
    visibility: String,
    supported_in_api: bool,
    priority: i32,
    #[serde(default)]
    additional_speed_tiers: Vec<String>,
    #[serde(default)]
    service_tiers: Vec<ServiceTier>,
    #[serde(default)]
    default_service_tier: Option<String>,
    #[serde(default)]
    availability_nux: Option<AvailabilityNux>,
    #[serde(default)]
    upgrade: Option<ModelUpgrade>,
    #[serde(default = "default_input_modalities")]
    input_modalities: Vec<String>,
    #[serde(default)]
    model_messages: Option<Value>,
    #[serde(skip)]
    is_default: bool,
}

#[derive(Clone, Deserialize, Serialize)]
struct ReasoningLevel {
    effort: String,
    #[serde(default)]
    description: String,
}

#[derive(Clone, Deserialize, Serialize)]
struct ServiceTier {
    id: String,
    name: String,
    description: String,
}

#[derive(Clone, Deserialize, Serialize)]
struct AvailabilityNux {
    message: String,
}

#[derive(Clone, Deserialize, Serialize)]
struct ModelUpgrade {
    model: String,
    #[serde(default)]
    migration_markdown: String,
}

fn default_input_modalities() -> Vec<String> {
    vec!["text".to_string(), "image".to_string()]
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct ProviderCapabilities {
    namespace_tools: bool,
    image_generation: bool,
    web_search: bool,
}

impl Default for ProviderCapabilities {
    fn default() -> Self {
        Self {
            namespace_tools: true,
            image_generation: true,
            web_search: true,
        }
    }
}

#[derive(Clone)]
pub(crate) struct ModelCatalogConfiguration {
    provider_id: String,
    account_identity: Option<String>,
    access_token: Option<String>,
    account_id: Option<String>,
    base_url: String,
    chatgpt_auth: bool,
    cache_directory: Option<PathBuf>,
    capabilities: ProviderCapabilities,
}

impl Default for ModelCatalogConfiguration {
    fn default() -> Self {
        Self {
            provider_id: "openai".to_string(),
            account_identity: None,
            access_token: None,
            account_id: None,
            base_url: DEFAULT_BASE_URL.to_string(),
            chatgpt_auth: false,
            cache_directory: None,
            capabilities: ProviderCapabilities::default(),
        }
    }
}

impl fmt::Debug for ModelCatalogConfiguration {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ModelCatalogConfiguration")
            .field("provider_id", &self.provider_id)
            .field("account_identity", &self.account_identity)
            .field(
                "access_token",
                &self.access_token.as_ref().map(|_| "[redacted]"),
            )
            .field("account_id", &self.account_id)
            .field("base_url", &self.base_url)
            .field("chatgpt_auth", &self.chatgpt_auth)
            .field("cache_directory", &self.cache_directory)
            .field("capabilities", &self.capabilities)
            .finish()
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ConfigureCommand {
    kind: String,
    provider_id: String,
    #[serde(default)]
    account_identity: Option<String>,
    #[serde(default)]
    access_token: Option<String>,
    #[serde(default)]
    account_id: Option<String>,
    #[serde(default)]
    base_url: Option<String>,
    #[serde(default)]
    chatgpt_auth: bool,
    #[serde(default)]
    cache_directory: Option<String>,
    #[serde(default)]
    capabilities: Option<ProviderCapabilities>,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ModelListParams {
    #[serde(default)]
    cursor: Option<String>,
    #[serde(default)]
    limit: Option<u32>,
    #[serde(default)]
    include_hidden: Option<bool>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ModelListResponse {
    data: Vec<WireModel>,
    next_cursor: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireModel {
    id: String,
    model: String,
    upgrade: Option<String>,
    upgrade_info: Option<WireUpgradeInfo>,
    availability_nux: Option<AvailabilityNux>,
    display_name: String,
    description: String,
    hidden: bool,
    supported_reasoning_efforts: Vec<WireReasoningEffort>,
    default_reasoning_effort: String,
    input_modalities: Vec<String>,
    supports_personality: bool,
    additional_speed_tiers: Vec<String>,
    service_tiers: Vec<ServiceTier>,
    default_service_tier: Option<String>,
    is_default: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireUpgradeInfo {
    model: String,
    upgrade_copy: Option<String>,
    model_link: Option<String>,
    migration_markdown: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireReasoningEffort {
    reasoning_effort: String,
    description: String,
}

impl From<ModelInfo> for WireModel {
    fn from(model: ModelInfo) -> Self {
        let supports_personality = supports_personality(model.model_messages.as_ref());
        let upgrade_info = model.upgrade.as_ref().map(|upgrade| WireUpgradeInfo {
            model: upgrade.model.clone(),
            upgrade_copy: None,
            model_link: None,
            migration_markdown: Some(upgrade.migration_markdown.clone()),
        });
        Self {
            id: model.slug.clone(),
            model: model.slug,
            upgrade: model.upgrade.as_ref().map(|upgrade| upgrade.model.clone()),
            upgrade_info,
            availability_nux: model.availability_nux,
            display_name: model.display_name,
            description: model.description.unwrap_or_default(),
            hidden: model.visibility != "list",
            supported_reasoning_efforts: model
                .supported_reasoning_levels
                .into_iter()
                .map(|level| WireReasoningEffort {
                    reasoning_effort: level.effort,
                    description: level.description,
                })
                .collect(),
            default_reasoning_effort: model
                .default_reasoning_level
                .unwrap_or_else(|| "none".to_string()),
            input_modalities: model.input_modalities,
            supports_personality,
            additional_speed_tiers: model.additional_speed_tiers,
            service_tiers: model.service_tiers,
            default_service_tier: model.default_service_tier,
            is_default: model.is_default,
        }
    }
}

fn supports_personality(messages: Option<&Value>) -> bool {
    let Some(messages) = messages.and_then(Value::as_object) else {
        return false;
    };
    let has_placeholder = messages
        .get("instructions_template")
        .and_then(Value::as_str)
        .is_some_and(|template| template.contains("{{ personality }}"));
    let Some(variables) = messages
        .get("instructions_variables")
        .and_then(Value::as_object)
    else {
        return false;
    };
    has_placeholder
        && [
            "personality_default",
            "personality_friendly",
            "personality_pragmatic",
        ]
        .iter()
        .all(|key| variables.get(*key).and_then(Value::as_str).is_some())
}

pub(crate) struct ModelCatalog {
    bundled: ModelsResponse,
    configuration: ModelCatalogConfiguration,
}

impl Default for ModelCatalog {
    fn default() -> Self {
        Self {
            bundled: embedded_models().unwrap_or(ModelsResponse { models: Vec::new() }),
            configuration: ModelCatalogConfiguration::default(),
        }
    }
}

impl ModelCatalog {
    #[cfg(test)]
    fn with_bundled(bundled: ModelsResponse) -> Self {
        Self {
            bundled,
            configuration: ModelCatalogConfiguration::default(),
        }
    }

    pub(crate) fn configure(&mut self, input: &[u8]) -> Result<(), CoreError> {
        let value: Value = serde_json::from_slice(input).map_err(|_| CoreError::InvalidJson)?;
        self.configure_value(value)
    }

    fn configure_value(&mut self, value: Value) -> Result<(), CoreError> {
        let command: ConfigureCommand =
            serde_json::from_value(value).map_err(|_| CoreError::InvalidJson)?;
        if command.kind != "model.catalog.configure"
            || command.provider_id.trim().is_empty()
            || optional_string_is_empty(command.account_identity.as_deref())
            || optional_string_is_empty(command.access_token.as_deref())
            || optional_string_is_empty(command.account_id.as_deref())
        {
            return Err(CoreError::InvalidArgument);
        }
        let base_url = command
            .base_url
            .unwrap_or_else(|| DEFAULT_BASE_URL.to_string());
        if !base_url.starts_with("https://") || base_url.ends_with('/') {
            return Err(CoreError::InvalidArgument);
        }
        let cache_directory = command.cache_directory.map(PathBuf::from);
        if cache_directory
            .as_deref()
            .is_some_and(|path| !path.is_absolute())
        {
            return Err(CoreError::InvalidArgument);
        }
        let capabilities = command.capabilities.unwrap_or_else(|| {
            if command.provider_id.eq_ignore_ascii_case("bedrock") {
                ProviderCapabilities {
                    namespace_tools: true,
                    image_generation: false,
                    web_search: false,
                }
            } else {
                ProviderCapabilities::default()
            }
        });
        self.configuration = ModelCatalogConfiguration {
            provider_id: command.provider_id,
            account_identity: command.account_identity,
            access_token: command.access_token,
            account_id: command.account_id,
            base_url,
            chatgpt_auth: command.chatgpt_auth,
            cache_directory,
            capabilities,
        };
        Ok(())
    }

    pub(crate) fn clear(&mut self) {
        self.configuration = ModelCatalogConfiguration::default();
    }

    pub(crate) fn request(&mut self, method: &str, params: &Value) -> Result<Vec<u8>, CoreError> {
        if !params.is_object() {
            return Err(CoreError::InvalidArgument);
        }
        match method {
            "model/list" => self.list(params),
            "modelProvider/capabilities/read" => {
                serde_json::to_vec(&self.configuration.capabilities)
                    .map_err(|_| CoreError::InvalidJson)
            }
            _ => Err(CoreError::UnsupportedCommand),
        }
    }

    fn list(&mut self, params: &Value) -> Result<Vec<u8>, CoreError> {
        let params: ModelListParams =
            serde_json::from_value(params.clone()).map_err(|_| CoreError::InvalidArgument)?;
        let remote = self.remote_models();
        let models = available_models(
            self.bundled.clone(),
            remote,
            self.configuration.chatgpt_auth,
        );
        let models = models
            .into_iter()
            .filter(|model| params.include_hidden.unwrap_or(false) || model.visibility == "list")
            .collect::<Vec<_>>();
        let total = models.len();
        if total == 0 {
            return serde_json::to_vec(&ModelListResponse {
                data: Vec::new(),
                next_cursor: None,
            })
            .map_err(|_| CoreError::InvalidJson);
        }
        let effective_limit = (params.limit.unwrap_or(total as u32).max(1) as usize).min(total);
        let start = match params.cursor {
            Some(cursor) => cursor
                .parse::<usize>()
                .map_err(|_| CoreError::InvalidArgument)?,
            None => 0,
        };
        if start > total {
            return Err(CoreError::InvalidArgument);
        }
        let end = start.saturating_add(effective_limit).min(total);
        let data = models[start..end]
            .iter()
            .cloned()
            .map(WireModel::from)
            .collect();
        serde_json::to_vec(&ModelListResponse {
            data,
            next_cursor: (end < total).then(|| end.to_string()),
        })
        .map_err(|_| CoreError::InvalidJson)
    }

    fn remote_models(&mut self) -> Option<ModelsResponse> {
        let now = unix_time_ms();
        let cached = load_cache(&self.configuration, now);
        if cached.as_ref().is_some_and(|cache| cache.is_fresh) {
            return cached.map(|cache| ModelsResponse {
                models: cache.models,
            });
        }
        if self.configuration.access_token.is_none() {
            return cached.map(|cache| ModelsResponse {
                models: cache.models,
            });
        }

        match fetch_models(
            &self.configuration,
            cached.as_ref().and_then(|cache| cache.etag.as_deref()),
        ) {
            Ok(RemoteFetch::Models { models, etag }) => {
                let _ = persist_cache(&self.configuration, now, etag.as_deref(), &models);
                Some(ModelsResponse { models })
            }
            Ok(RemoteFetch::NotModified) => {
                let cached = cached?;
                let _ = persist_cache(
                    &self.configuration,
                    now,
                    cached.etag.as_deref(),
                    &cached.models,
                );
                Some(ModelsResponse {
                    models: cached.models,
                })
            }
            Err(()) => cached.map(|cache| ModelsResponse {
                models: cache.models,
            }),
        }
    }
}

fn optional_string_is_empty(value: Option<&str>) -> bool {
    value.is_some_and(|value| value.trim().is_empty())
}

fn embedded_models() -> Result<ModelsResponse, serde_json::Error> {
    serde_json::from_str(include_str!("../resources/models.json"))
}

fn available_models(
    bundled: ModelsResponse,
    remote: Option<ModelsResponse>,
    chatgpt_auth: bool,
) -> Vec<ModelInfo> {
    let remote = remote.unwrap_or(ModelsResponse { models: Vec::new() });
    let has_visible_remote = remote.models.iter().any(|model| model.visibility == "list");
    let mut models = if chatgpt_auth && has_visible_remote {
        deduplicate_models(remote.models)
    } else {
        let mut merged = BTreeMap::new();
        for model in bundled.models.into_iter().chain(remote.models) {
            merged.insert(model.slug.clone(), model);
        }
        merged.into_values().collect()
    };
    models.retain(|model| {
        (chatgpt_auth || model.supported_in_api)
            && !model.slug.is_empty()
            && !model.display_name.is_empty()
            && matches!(model.visibility.as_str(), "list" | "hide" | "none")
            && model
                .supported_reasoning_levels
                .iter()
                .all(|level| !level.effort.is_empty())
    });
    models.sort_by(|left, right| {
        left.priority
            .cmp(&right.priority)
            .then_with(|| left.slug.cmp(&right.slug))
    });
    for model in &mut models {
        model.is_default = false;
    }
    let default_index = models
        .iter()
        .position(|model| model.visibility == "list")
        .or_else(|| (!models.is_empty()).then_some(0));
    if let Some(default_index) = default_index {
        models[default_index].is_default = true;
    }
    models
}

fn deduplicate_models(models: Vec<ModelInfo>) -> Vec<ModelInfo> {
    let mut deduplicated = BTreeMap::new();
    for model in models {
        deduplicated.insert(model.slug.clone(), model);
    }
    deduplicated.into_values().collect()
}

enum RemoteFetch {
    Models {
        models: Vec<ModelInfo>,
        etag: Option<String>,
    },
    NotModified,
}

fn fetch_models(
    configuration: &ModelCatalogConfiguration,
    etag: Option<&str>,
) -> Result<RemoteFetch, ()> {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|_| ())?;
    runtime.block_on(fetch_models_async(configuration, etag))
}

async fn fetch_models_async(
    configuration: &ModelCatalogConfiguration,
    etag: Option<&str>,
) -> Result<RemoteFetch, ()> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(15))
        .build()
        .map_err(|_| ())?;
    let token = configuration.access_token.as_deref().ok_or(())?;
    let mut request = client
        .get(models_endpoint(configuration))
        .bearer_auth(token);
    if let Some(account_id) = configuration.account_id.as_deref() {
        request = request.header("ChatGPT-Account-ID", account_id);
    }
    if let Some(etag) = etag {
        request = request.header(header::IF_NONE_MATCH, etag);
    }
    let response = request.send().await.map_err(|_| ())?;
    if response.status() == reqwest::StatusCode::NOT_MODIFIED {
        return Ok(RemoteFetch::NotModified);
    }
    if !response.status().is_success() {
        return Err(());
    }
    let etag = response
        .headers()
        .get(header::ETAG)
        .and_then(|value| value.to_str().ok())
        .map(ToOwned::to_owned);
    let bytes = response.bytes().await.map_err(|_| ())?;
    let response: ModelsResponse = serde_json::from_slice(&bytes).map_err(|_| ())?;
    Ok(RemoteFetch::Models {
        models: response.models,
        etag,
    })
}

fn models_endpoint(configuration: &ModelCatalogConfiguration) -> String {
    format!(
        "{}/models?client_version={}",
        configuration.base_url,
        client_version_whole()
    )
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct CacheRecord {
    schema_version: u32,
    client_version: String,
    fetched_at_ms: u64,
    etag: Option<String>,
    models: Vec<ModelInfo>,
}

struct LoadedCache {
    models: Vec<ModelInfo>,
    etag: Option<String>,
    is_fresh: bool,
}

fn cache_path(configuration: &ModelCatalogConfiguration) -> PathBuf {
    let identity = format!(
        "{}\0{}\0{}\0{}",
        configuration.provider_id,
        configuration.account_identity.as_deref().unwrap_or(""),
        configuration.base_url,
        client_version_whole()
    );
    let partition = fnv1a64(identity.as_bytes());
    configuration
        .cache_directory
        .clone()
        .unwrap_or_default()
        .join(format!("models-{partition:016x}.json"))
}

fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

fn load_cache(configuration: &ModelCatalogConfiguration, now_ms: u64) -> Option<LoadedCache> {
    configuration.cache_directory.as_ref()?;
    let bytes = fs::read(cache_path(configuration)).ok()?;
    let record: CacheRecord = serde_json::from_slice(&bytes).ok()?;
    if record.schema_version != CACHE_SCHEMA_VERSION
        || record.client_version != client_version_whole()
    {
        return None;
    }
    Some(LoadedCache {
        models: record.models,
        etag: record.etag,
        is_fresh: now_ms.saturating_sub(record.fetched_at_ms) <= CACHE_TTL_MS,
    })
}

fn persist_cache(
    configuration: &ModelCatalogConfiguration,
    fetched_at_ms: u64,
    etag: Option<&str>,
    models: &[ModelInfo],
) -> Result<(), ()> {
    let Some(directory) = configuration.cache_directory.as_deref() else {
        return Ok(());
    };
    fs::create_dir_all(directory).map_err(|_| ())?;
    let path = cache_path(configuration);
    let temporary = path.with_extension("json.tmp");
    let record = CacheRecord {
        schema_version: CACHE_SCHEMA_VERSION,
        client_version: client_version_whole(),
        fetched_at_ms,
        etag: etag.map(ToOwned::to_owned),
        models: models.to_vec(),
    };
    let bytes = serde_json::to_vec(&record).map_err(|_| ())?;
    let mut file = fs::File::create(&temporary).map_err(|_| ())?;
    file.write_all(&bytes).map_err(|_| ())?;
    file.sync_all().map_err(|_| ())?;
    set_owner_only_permissions(&temporary)?;
    fs::rename(&temporary, &path).map_err(|_| ())?;
    Ok(())
}

#[cfg(unix)]
fn set_owner_only_permissions(path: &Path) -> Result<(), ()> {
    use std::os::unix::fs::PermissionsExt;

    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).map_err(|_| ())
}

#[cfg(not(unix))]
fn set_owner_only_permissions(_path: &Path) -> Result<(), ()> {
    Ok(())
}

fn unix_time_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .try_into()
        .unwrap_or(u64::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use tempfile::TempDir;

    fn model_fixture(
        slug: &str,
        display_name: &str,
        priority: i32,
        visibility: &str,
        supported_in_api: bool,
    ) -> ModelInfo {
        ModelInfo {
            slug: slug.to_string(),
            display_name: display_name.to_string(),
            description: Some(format!("{display_name} description")),
            default_reasoning_level: Some("focused".to_string()),
            supported_reasoning_levels: vec![ReasoningLevel {
                effort: "focused".to_string(),
                description: "Focused".to_string(),
            }],
            visibility: visibility.to_string(),
            supported_in_api,
            priority,
            additional_speed_tiers: Vec::new(),
            service_tiers: Vec::new(),
            default_service_tier: None,
            availability_nux: None,
            upgrade: None,
            input_modalities: default_input_modalities(),
            model_messages: None,
            is_default: false,
        }
    }

    fn configuration_fixture(
        cache_directory: &Path,
        provider_id: &str,
        account_identity: Option<&str>,
        token: &str,
    ) -> ModelCatalogConfiguration {
        ModelCatalogConfiguration {
            provider_id: provider_id.to_string(),
            account_identity: account_identity.map(ToOwned::to_owned),
            access_token: Some(token.to_string()),
            account_id: account_identity.map(ToOwned::to_owned),
            base_url: DEFAULT_BASE_URL.to_string(),
            chatgpt_auth: true,
            cache_directory: Some(cache_directory.to_path_buf()),
            capabilities: ProviderCapabilities::default(),
        }
    }

    fn response(value: Vec<u8>) -> serde_json::Value {
        serde_json::from_slice(&value).expect("valid response")
    }

    #[test]
    fn bundled_catalog_lists_all_visible_models_losslessly() {
        let mut catalog = ModelCatalog::default();
        let value = response(
            catalog
                .request("model/list", &json!({}))
                .expect("bundled model list"),
        );
        let models = value["data"].as_array().expect("model data");

        assert_eq!(models.len(), 7);
        assert_eq!(models[0]["id"], "gpt-5.6-sol");
        assert_eq!(models[0]["model"], "gpt-5.6-sol");
        assert_eq!(models[0]["isDefault"], true);
        assert_eq!(models[0]["supportsPersonality"], false);
        assert_eq!(models[3]["id"], "gpt-5.5");
        assert_eq!(models[3]["supportsPersonality"], true);
        assert_eq!(models[4]["id"], "gpt-5.4");
        assert_eq!(models[5]["id"], "gpt-5.4-mini");
        assert_eq!(models[6]["id"], "gpt-5.3-codex-spark");
        assert_eq!(models[6]["inputModalities"], json!(["text"]));
        assert_eq!(models[0]["defaultServiceTier"], serde_json::Value::Null);
        assert_eq!(
            models[0]["supportedReasoningEfforts"][5]["reasoningEffort"],
            "ultra"
        );
        assert_eq!(value["nextCursor"], serde_json::Value::Null);
    }

    #[test]
    fn current_desktop_snapshot_obeys_exact_official_pagination_rules() {
        let mut catalog = ModelCatalog::default();
        let page = response(
            catalog
                .request("model/list", &json!({"includeHidden": true, "limit": 0}))
                .expect("first page"),
        );
        assert_eq!(page["data"].as_array().map(Vec::len), Some(1));
        assert_eq!(page["nextCursor"], "1");

        let last = response(
            catalog
                .request(
                    "model/list",
                    &json!({
                        "includeHidden": true,
                        "cursor": "7",
                        "limit": 1
                    }),
                )
                .expect("empty final page"),
        );
        assert_eq!(last["data"], json!([]));
        assert_eq!(last["nextCursor"], serde_json::Value::Null);

        assert_eq!(
            catalog.request("model/list", &json!({"cursor": "invalid"})),
            Err(crate::CoreError::InvalidArgument)
        );
        assert_eq!(
            catalog.request("model/list", &json!({"includeHidden": true, "cursor": "8"})),
            Err(crate::CoreError::InvalidArgument)
        );
    }

    #[test]
    fn an_empty_catalog_short_circuits_even_an_invalid_cursor() {
        let mut catalog = ModelCatalog::with_bundled(ModelsResponse { models: Vec::new() });
        let value = response(
            catalog
                .request("model/list", &json!({"cursor": "invalid"}))
                .expect("empty list"),
        );

        assert_eq!(value, json!({"data": [], "nextCursor": null}));
    }

    #[test]
    fn chatgpt_visible_remote_catalog_is_the_source_of_truth() {
        let bundled = embedded_models().expect("embedded catalog");
        let remote = ModelsResponse {
            models: vec![model_fixture(
                "remote-only",
                "Remote Only",
                0,
                "list",
                false,
            )],
        };

        let models = available_models(bundled, Some(remote), true);

        assert_eq!(models.len(), 1);
        assert_eq!(models[0].slug, "remote-only");
        assert!(models[0].is_default);
    }

    #[test]
    fn non_chatgpt_catalog_merges_by_slug_and_filters_api_support() {
        let bundled = ModelsResponse {
            models: vec![
                model_fixture("shared", "Bundled", 2, "list", true),
                model_fixture("bundled", "Bundled Only", 3, "list", true),
            ],
        };
        let remote = ModelsResponse {
            models: vec![
                model_fixture("shared", "Remote Override", 1, "list", true),
                model_fixture("private", "Private", 0, "list", false),
            ],
        };

        let models = available_models(bundled, Some(remote), false);

        assert_eq!(
            models
                .iter()
                .map(|model| model.slug.as_str())
                .collect::<Vec<_>>(),
            vec!["shared", "bundled"]
        );
        assert_eq!(models[0].display_name, "Remote Override");
        assert!(models[0].is_default);
    }

    #[test]
    fn provider_capabilities_use_exact_wire_shape() {
        let mut catalog = ModelCatalog::default();
        catalog
            .configure_value(json!({
                "kind": "model.catalog.configure",
                "providerId": "bedrock",
                "accountIdentity": null,
                "accessToken": null,
                "accountId": null,
                "baseUrl": "https://example.test",
                "chatgptAuth": false,
                "cacheDirectory": null,
                "capabilities": {
                    "namespaceTools": true,
                    "imageGeneration": false,
                    "webSearch": false
                }
            }))
            .expect("configuration");

        let value = response(
            catalog
                .request("modelProvider/capabilities/read", &json!({}))
                .expect("capabilities"),
        );
        assert_eq!(
            value,
            json!({
                "namespaceTools": true,
                "imageGeneration": false,
                "webSearch": false
            })
        );
    }

    #[test]
    fn cache_partition_never_depends_on_or_exposes_the_access_token() {
        let directory = TempDir::new().expect("cache directory");
        let first = configuration_fixture(
            directory.path(),
            "provider-a",
            Some("account-a"),
            "first-secret",
        );
        let second = configuration_fixture(
            directory.path(),
            "provider-a",
            Some("account-a"),
            "second-secret",
        );
        let another_account = configuration_fixture(
            directory.path(),
            "provider-a",
            Some("account-b"),
            "first-secret",
        );

        assert_eq!(cache_path(&first), cache_path(&second));
        assert_ne!(cache_path(&first), cache_path(&another_account));
        assert!(!format!("{first:?}").contains("first-secret"));
        assert!(!cache_path(&first)
            .to_string_lossy()
            .contains("first-secret"));
    }

    #[test]
    fn cache_round_trip_preserves_etag_models_and_ttl() {
        let directory = TempDir::new().expect("cache directory");
        let config =
            configuration_fixture(directory.path(), "provider-a", Some("account-a"), "secret");
        let models = vec![model_fixture("cached", "Cached", 0, "list", true)];
        persist_cache(&config, 1_000_000, Some("\"etag-1\""), &models).expect("persist cache");

        let fresh = load_cache(&config, 1_299_999).expect("fresh cache");
        assert!(fresh.is_fresh);
        assert_eq!(fresh.etag.as_deref(), Some("\"etag-1\""));
        assert_eq!(fresh.models[0].slug, "cached");

        let stale = load_cache(&config, 1_300_001).expect("stale cache");
        assert!(!stale.is_fresh);
    }

    #[test]
    fn model_endpoint_uses_pinned_cli_client_version() {
        let config = configuration_fixture(
            TempDir::new().expect("cache").path(),
            "openai",
            Some("account"),
            "secret",
        );

        assert_eq!(
            models_endpoint(&config),
            "https://chatgpt.com/backend-api/codex/models?client_version=0.150.0"
        );
    }

    #[test]
    fn core_dispatches_model_requests_and_echoes_string_or_integer_ids() {
        let mut core = crate::CodexCore::default();
        let listed = response(
            core.request(br#"{"id":"models","method":"model/list","params":{}}"#)
                .expect("model/list through core"),
        );
        assert_eq!(listed["id"], "models");
        assert_eq!(listed["result"]["data"].as_array().map(Vec::len), Some(7));

        let capabilities = response(
            core.request(br#"{"id":42,"method":"modelProvider/capabilities/read","params":{}}"#)
                .expect("capabilities through core"),
        );
        assert_eq!(capabilities["id"], 42);
        assert_eq!(capabilities["result"]["namespaceTools"], true);
    }

    #[test]
    fn model_configuration_is_ephemeral_and_does_not_consume_event_sequence() {
        let mut core = crate::CodexCore::default();
        core.submit(
            br#"{"kind":"model.catalog.configure","providerId":"bedrock","accountIdentity":"account","accessToken":"secret-in-memory-only","accountId":null,"baseUrl":"https://example.test","chatgptAuth":false,"cacheDirectory":null}"#,
        )
        .expect("configure model catalog");

        assert_eq!(core.next_sequence, 1);
        assert!(core.events.is_empty());
        let capabilities = response(
            core.request(br#"{"method":"modelProvider/capabilities/read","params":{}}"#)
                .expect("configured capabilities"),
        );
        assert_eq!(
            capabilities,
            json!({
                "namespaceTools": true,
                "imageGeneration": false,
                "webSearch": false
            })
        );
    }
}
