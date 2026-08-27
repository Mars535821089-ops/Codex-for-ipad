use codex_core::{
    CodexCoreBuffer, CodexCoreHandle, CodexCoreStatus, codex_core_buffer_free, codex_core_create,
    codex_core_destroy, codex_core_next_event_json, codex_core_submit_json,
};
use serde_json::json;
use std::path::Path;
use std::slice;

const SESSION_COMMANDS: [&[u8]; 4] = [
    br#"{"kind":"workspace.open","workspace":{"id":"11111111-1111-1111-1111-111111111111","displayName":"Mars Project","rootBookmarkId":null}}"#,
    br#"{"kind":"thread.start","thread":{"id":"22222222-2222-2222-2222-222222222222","workspaceId":"11111111-1111-1111-1111-111111111111","title":"First thread"}}"#,
    br#"{"kind":"turn.start","turn":{"id":"33333333-3333-3333-3333-333333333333","threadId":"22222222-2222-2222-2222-222222222222","status":"running"},"userItem":{"id":"44444444-4444-4444-4444-444444444444","threadId":"22222222-2222-2222-2222-222222222222","turnId":"33333333-3333-3333-3333-333333333333","kind":"userMessage","text":"Inspect this workspace"}}"#,
    br#"{"kind":"turn.complete","turnId":"33333333-3333-3333-3333-333333333333","assistantItem":{"id":"55555555-5555-5555-5555-555555555555","threadId":"22222222-2222-2222-2222-222222222222","turnId":"33333333-3333-3333-3333-333333333333","kind":"assistantMessage","text":"Workspace inspection complete"}}"#,
];

fn submit(handle: *mut CodexCoreHandle, command: &[u8]) {
    assert_eq!(
        codex_core_submit_json(handle, command.as_ptr(), command.len()),
        CodexCoreStatus::Ok
    );
}

fn storage_command(kind: &str, database: &Path, snapshots: &Path) -> Vec<u8> {
    serde_json::to_vec(&json!({
        "kind": kind,
        "databasePath": database,
        "snapshotDirectory": snapshots,
    }))
    .expect("storage command must encode")
}

fn drain(handle: *mut CodexCoreHandle, count: usize, print: bool) {
    let mut output = CodexCoreBuffer::default();
    for _ in 0..count {
        assert_eq!(
            codex_core_next_event_json(handle, &mut output),
            CodexCoreStatus::Ok
        );
        let event = unsafe { slice::from_raw_parts(output.ptr, output.len) };
        if print {
            println!(
                "{}",
                std::str::from_utf8(event).expect("event must be UTF-8")
            );
        }
        codex_core_buffer_free(&mut output);
    }
    assert_eq!(
        codex_core_next_event_json(handle, &mut output),
        CodexCoreStatus::NoEvent
    );
}

fn replay(root: &Path) {
    let database = root.join("CodexPad.sqlite");
    let snapshots = root.join("MigrationSnapshots");
    let open = storage_command("storage.open", &database, &snapshots);

    let first = codex_core_create();
    assert!(!first.is_null());
    submit(first, &open);
    for command in SESSION_COMMANDS {
        submit(first, command);
    }
    drain(first, 6, false);
    codex_core_destroy(first);

    let second = codex_core_create();
    assert!(!second.is_null());
    submit(second, &open);
    drain(second, 6, true);
    submit(
        second,
        br#"{"kind":"workspace.open","workspace":{"id":"66666666-6666-6666-6666-666666666666","displayName":"Continued","rootBookmarkId":null}}"#,
    );
    drain(second, 1, true);
    codex_core_destroy(second);
}

fn legacy_snapshot(root: &Path, confirm: bool) {
    let database = root.join("CodexPad.sqlite");
    let snapshots = root.join("MigrationSnapshots");
    let snapshot = snapshots.join("schema-0-to-3.sqlite");
    let open = storage_command("storage.open", &database, &snapshots);

    let handle = codex_core_create();
    assert!(!handle.is_null());
    submit(handle, &open);
    println!("snapshot-before-confirm={}", snapshot.is_file());
    if confirm {
        submit(handle, br#"{"kind":"storage.confirm"}"#);
        println!("snapshot-after-confirm={}", snapshot.is_file());
    }
    codex_core_destroy(handle);
}

fn main() {
    let mut arguments = std::env::args_os().skip(1);
    let mode = arguments.next().expect("mode argument is required");
    let root = arguments.next().expect("root argument is required");
    assert!(arguments.next().is_none(), "unexpected extra argument");
    let root = Path::new(&root);
    assert!(root.is_absolute(), "root must be absolute");

    match mode.to_str() {
        Some("replay") => replay(root),
        Some("legacy-open") => legacy_snapshot(root, false),
        Some("legacy-confirm") => legacy_snapshot(root, true),
        _ => panic!("unsupported mode"),
    }
}
