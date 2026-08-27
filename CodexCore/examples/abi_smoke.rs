use codex_core::{
    CodexCoreBuffer, CodexCoreStatus, codex_core_buffer_free, codex_core_create,
    codex_core_destroy, codex_core_next_event_json, codex_core_submit_json,
};
use std::slice;

fn main() {
    let handle = codex_core_create();
    assert!(!handle.is_null());

    let command = br#"{"kind":"ping","requestId":"phase-05"}"#;
    assert_eq!(
        codex_core_submit_json(handle, command.as_ptr(), command.len()),
        CodexCoreStatus::Ok
    );

    let mut output = CodexCoreBuffer::default();
    assert_eq!(
        codex_core_next_event_json(handle, &mut output),
        CodexCoreStatus::Ok
    );
    assert!(!output.ptr.is_null());
    let event = unsafe { slice::from_raw_parts(output.ptr, output.len) };
    println!(
        "{}",
        std::str::from_utf8(event).expect("event must be UTF-8")
    );

    codex_core_buffer_free(&mut output);
    assert!(output.ptr.is_null());
    assert_eq!(output.len, 0);
    assert_eq!(output.capacity, 0);
    assert_eq!(
        codex_core_next_event_json(handle, &mut output),
        CodexCoreStatus::NoEvent
    );

    codex_core_destroy(handle);
}
