use crate::{CoreError, git_diff};
use flate2::Compression;
use flate2::read::ZlibDecoder;
use flate2::write::GzEncoder;
use gix::bstr::ByteSlice;
use serde::Deserialize;
use serde_json::{Value, json};
use sha1::{Digest, Sha1};
use sha2::Sha256;
use std::collections::BTreeSet;
use std::fs;
use std::io::Read;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct GitWorkerRequest {
    method: String,
    #[serde(default)]
    params: Value,
}

pub(super) fn request(params: &Value) -> Result<Vec<u8>, CoreError> {
    let request: GitWorkerRequest =
        serde_json::from_value(params.clone()).map_err(|_| CoreError::InvalidArgument)?;
    let params = request
        .params
        .as_object()
        .ok_or(CoreError::InvalidArgument)?;
    let result = match request.method.as_str() {
        "availability" => json!({"available": true}),
        "stable-metadata" => stable_metadata(required_path(params, "cwd")?)?,
        "current-branch" | "current-branch-snapshot" => {
            let repository = discover(required_path(params, "root")?)?;
            json!({"branch": current_branch(&repository)?})
        }
        "clone-state" => clone_state(required_path(params, "root")?)?,
        "branch-exists" => {
            let repository = discover(required_path(params, "root")?)?;
            let branch = required_string(params, "branch")?;
            let exists = repository
                .try_find_reference(format!("refs/heads/{branch}").as_str())
                .map_err(|_| CoreError::InvalidArgument)?
                .is_some();
            json!({"exists": exists})
        }
        "config-value" => config_value(params)?,
        "status-summary" => {
            let cwd = required_path(params, "cwd")?;
            let include_untracked = params
                .get("includeUntrackedFiles")
                .and_then(Value::as_bool)
                .unwrap_or(true);
            let counts = git_diff::status_counts(cwd, include_untracked)
                .map_err(|_| CoreError::InvalidArgument)?;
            json!({
                "type": "success",
                "stagedCount": counts.staged,
                "unstagedCount": counts.unstaged,
                "untrackedCount": counts.untracked,
            })
        }
        "upstream-branch" => upstream_branch(required_path(params, "root")?)?,
        "default-branch" => default_branch(required_path(params, "root")?)?,
        "base-branch" => base_branch(required_path(params, "root")?)?,
        "branch-metadata" => branch_metadata(required_path(params, "cwd")?)?,
        "git-origins" => git_origins(params)?,
        "index-info" => index_info(required_path(params, "cwd")?)?,
        "submodule-paths" => submodule_paths(required_path(params, "root")?)?,
        "recent-branches" => recent_branches(params)?,
        "search-branches" => search_branches(params)?,
        "branch-ahead-count" => branch_ahead_count(required_path(params, "root")?)?,
        "branch-commits" => branch_commits(params)?,
        "commit-message-diff" => commit_message_diff(params)?,
        "review-patch" => review_patch(params)?,
        "review-diff" => review_diff(params)?,
        "review-search" => review_search(params)?,
        "branch-diff-stats" => branch_diff_stats(params)?,
        "review-summary" => review_summary(params)?,
        "blame-file" => blame_file(params)?,
        "synced-branch" => synced_branch(params)?,
        "synced-branch-state" => synced_branch_state(params)?,
        "worktree-snapshot-ref" => worktree_snapshot_ref(params)?,
        "managed-worktree-state" => managed_worktree_state(params)?,
        "list-worktrees" => list_worktrees(params)?,
        "codex-worktrees" => codex_worktrees(params)?,
        "git-init-repo" => git_init_repo(params)?,
        "git-create-branch" => git_create_branch(params)?,
        "git-checkout-branch" => git_checkout_branch(params)?,
        "git-merge-base" => git_merge_base(params)?,
        "git-push" => git_push(params)?,
        "prepare-worktree-snapshot" => prepare_worktree_snapshot(params)?,
        "worktree-shell-environment-config" => worktree_shell_environment_config(params)?,
        "set-config-value" => set_config_value(params)?,
        "commit" => commit_staged(params)?,
        "apply-patch" => apply_patch(params)?,
        "apply-changes" => apply_changes(params)?,
        "apply-review-section-changes" => apply_review_section_changes(params)?,
        "create-worktree" => create_worktree(params)?,
        "delete-worktree" => delete_worktree(params)?,
        "restore-worktree" => restore_worktree(params)?,
        "turn-diff-capture-start" => turn_diff_capture_start(params)?,
        "turn-diff-capture-complete" => turn_diff_capture_complete(params)?,
        "overwrite-repo" => overwrite_repository(params)?,
        "move-thread-to-local" => move_thread_to_local(params)?,
        "move-thread-to-worktree" => move_thread_to_worktree(params)?,
        "move-thread-to-host-worktree" => move_thread_to_host_worktree(params)?,
        "cleanup-host-handoff-transfer" => cleanup_host_handoff_transfer(params)?,
        "set-worktree-owner-thread" => set_worktree_owner_thread(params)?,
        "resolve-worktree-for-thread" => resolve_worktree_for_thread(params)?,
        "cat-file" => cat_file(params)?,
        _ => return Err(CoreError::UnsupportedCommand),
    };
    serde_json::to_vec(&result).map_err(|_| CoreError::InvalidJson)
}

fn required_string<'a>(
    params: &'a serde_json::Map<String, Value>,
    name: &str,
) -> Result<&'a str, CoreError> {
    params
        .get(name)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty() && !value.contains('\0'))
        .ok_or(CoreError::InvalidArgument)
}

fn required_path<'a>(
    params: &'a serde_json::Map<String, Value>,
    name: &str,
) -> Result<&'a Path, CoreError> {
    Ok(Path::new(required_string(params, name)?))
}

fn discover(path: &Path) -> Result<gix::Repository, CoreError> {
    gix::discover(path).map_err(|_| CoreError::InvalidArgument)
}

fn utf8(bytes: &[u8]) -> Result<String, CoreError> {
    bytes
        .to_str()
        .map(str::to_owned)
        .map_err(|_| CoreError::InvalidArgument)
}

fn current_branch(repository: &gix::Repository) -> Result<Option<String>, CoreError> {
    let name = repository
        .head_name()
        .map_err(|_| CoreError::InvalidArgument)?;
    let Some(name) = name else {
        return Ok(None);
    };
    let name = name.as_bstr().as_bytes();
    let Some(short) = name.strip_prefix(b"refs/heads/") else {
        return Ok(None);
    };
    utf8(short).map(Some)
}

fn append_snapshot_directory(
    archive: &mut tar::Builder<GzEncoder<fs::File>>,
    source: &Path,
    relative: &Path,
) -> Result<(), CoreError> {
    let archive_path = if relative.as_os_str().is_empty() {
        Path::new(".")
    } else {
        relative
    };
    archive
        .append_dir(archive_path, source)
        .map_err(|_| CoreError::InvalidArgument)?;
    let entries = fs::read_dir(source).map_err(|_| CoreError::InvalidArgument)?;
    for entry in entries {
        let entry = entry.map_err(|_| CoreError::InvalidArgument)?;
        let name = entry.file_name();
        if relative.as_os_str().is_empty() && name == ".git" {
            continue;
        }
        let path = entry.path();
        let child_relative = relative.join(name);
        let file_type = entry.file_type().map_err(|_| CoreError::InvalidArgument)?;
        if file_type.is_dir() {
            append_snapshot_directory(archive, &path, &child_relative)?;
        } else {
            archive
                .append_path_with_name(&path, &child_relative)
                .map_err(|_| CoreError::InvalidArgument)?;
        }
    }
    Ok(())
}

fn prepare_worktree_snapshot(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let repository = discover(required_path(params, "gitRoot")?)?;
    let workdir = repository.workdir().ok_or(CoreError::InvalidArgument)?;
    let commit_sha = repository
        .head_id()
        .map_err(|_| CoreError::InvalidArgument)?
        .detach()
        .to_string();
    let snapshot_branch = match params.get("snapshotBranch") {
        None | Some(Value::Null) => current_branch(&repository)?,
        Some(Value::String(value)) if !value.is_empty() && !value.contains('\0') => {
            Some(value.clone())
        }
        _ => return Err(CoreError::InvalidArgument),
    };
    let repo_name = workdir
        .file_name()
        .and_then(|name| name.to_str())
        .filter(|name| !name.is_empty())
        .ok_or(CoreError::InvalidArgument)?
        .to_owned();
    let created_at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| CoreError::InvalidArgument)?
        .as_nanos();
    let tarball_filename = format!("{repo_name}-{created_at}.tar.gz");
    let tarball_path = std::env::temp_dir().join(&tarball_filename);
    let file = fs::File::create(&tarball_path).map_err(|_| CoreError::InvalidArgument)?;
    let encoder = GzEncoder::new(file, Compression::default());
    let mut archive = tar::Builder::new(encoder);
    append_snapshot_directory(&mut archive, workdir, Path::new(""))?;
    let encoder = archive
        .into_inner()
        .map_err(|_| CoreError::InvalidArgument)?;
    encoder.finish().map_err(|_| CoreError::InvalidArgument)?;
    let tarball_size = fs::metadata(&tarball_path)
        .map_err(|_| CoreError::InvalidArgument)?
        .len();
    let config = repository.config_snapshot();
    let mut remotes = serde_json::Map::new();
    for remote_name in repository.remote_names().iter() {
        let name = remote_name
            .as_bstr()
            .to_str()
            .map_err(|_| CoreError::InvalidArgument)?;
        let key = format!("remote.{name}.url");
        if let Some(url) = config.string(key.as_str()) {
            remotes.insert(name.to_owned(), Value::String(utf8(url.as_ref())?));
        }
    }
    Ok(json!({
        "repoName": repo_name,
        "tarballFilename": tarball_filename,
        "tarballSize": tarball_size,
        "tarballPath": tarball_path.to_string_lossy(),
        "contentType": "application/gzip",
        "remotes": remotes,
        "commitSha": commit_sha,
        "snapshotBranch": snapshot_branch,
    }))
}

fn optional_string<'a>(
    params: &'a serde_json::Map<String, Value>,
    name: &str,
) -> Result<Option<&'a str>, CoreError> {
    match params.get(name) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) if !value.is_empty() && !value.contains('\0') => Ok(Some(value)),
        _ => Err(CoreError::InvalidArgument),
    }
}

fn git_push(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let cwd = required_path(params, "cwd")?;
    let force = params
        .get("force")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let set_upstream = params
        .get("setUpstream")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let requested_refspec = optional_string(params, "refspec")?;
    let username = optional_string(params, "username")?;
    let password = optional_string(params, "password")?;

    let repository = git2::Repository::discover(cwd).map_err(|_| CoreError::InvalidArgument)?;
    let local_branch = repository
        .head()
        .ok()
        .and_then(|head| head.shorthand().map(str::to_owned));
    let remote_name = local_branch
        .as_deref()
        .and_then(|branch| {
            repository
                .config()
                .ok()?
                .get_string(&format!("branch.{branch}.remote"))
                .ok()
        })
        .filter(|name| name != ".")
        .or_else(|| {
            repository
                .find_remote("origin")
                .ok()
                .map(|_| "origin".to_owned())
        })
        .or_else(|| {
            repository
                .remotes()
                .ok()?
                .iter()
                .flatten()
                .next()
                .map(str::to_owned)
        })
        .ok_or(CoreError::InvalidArgument)?;
    let mut remote = repository
        .find_remote(&remote_name)
        .map_err(|_| CoreError::InvalidArgument)?;

    let raw_refspec = requested_refspec
        .map(str::to_owned)
        .or_else(|| {
            local_branch
                .as_ref()
                .map(|branch| format!("{branch}:{branch}"))
        })
        .ok_or(CoreError::InvalidArgument)?;
    let (source, destination) = split_push_refspec(&raw_refspec)?;
    let normalized_source = normalize_push_source(source);
    let normalized_destination = normalize_push_destination(destination);
    let force_prefix = if force && !raw_refspec.starts_with('+') {
        "+"
    } else {
        ""
    };
    let refspec = format!("{force_prefix}{normalized_source}:{normalized_destination}");
    let mut callbacks = git2::RemoteCallbacks::new();
    if let Some(password) = password {
        callbacks.credentials(move |_url, username_from_url, allowed| {
            if allowed.contains(git2::CredentialType::USER_PASS_PLAINTEXT) {
                git2::Cred::userpass_plaintext(
                    username.or(username_from_url).unwrap_or("git"),
                    password,
                )
            } else if allowed.contains(git2::CredentialType::USERNAME) {
                git2::Cred::username(username.or(username_from_url).unwrap_or("git"))
            } else {
                Err(git2::Error::from_str(
                    "remote credential type is unsupported",
                ))
            }
        });
    }
    let mut options = git2::PushOptions::new();
    options.remote_callbacks(callbacks);
    let push_result = remote.push(&[refspec.as_str()], Some(&mut options));
    if let Err(error) = push_result {
        return Ok(json!({
            "status": "error",
            "execOutput": sanitize_git_error(&error.message()),
        }));
    }

    if set_upstream {
        let source_branch = source.strip_prefix("refs/heads/").unwrap_or(source);
        let destination_branch = destination
            .strip_prefix("refs/heads/")
            .unwrap_or(destination);
        if source_branch.is_empty() || destination_branch.is_empty() {
            return Err(CoreError::InvalidArgument);
        }
        let mut config = repository
            .config()
            .map_err(|_| CoreError::InvalidArgument)?;
        config
            .set_str(&format!("branch.{source_branch}.remote"), &remote_name)
            .map_err(|_| CoreError::InvalidArgument)?;
        config
            .set_str(
                &format!("branch.{source_branch}.merge"),
                &format!("refs/heads/{destination_branch}"),
            )
            .map_err(|_| CoreError::InvalidArgument)?;
    }
    Ok(json!({
        "status": "success",
        "execOutput": format!(
            "To {}\n   {} -> {}",
            sanitize_remote_url(remote.url().unwrap_or(&remote_name)),
            source,
            destination
        ),
    }))
}

fn normalize_push_source(reference: &str) -> String {
    if reference.starts_with("refs/")
        || reference == "HEAD"
        || (reference.len() == 40 && reference.bytes().all(|byte| byte.is_ascii_hexdigit()))
    {
        reference.to_owned()
    } else {
        format!("refs/heads/{reference}")
    }
}

fn normalize_push_destination(reference: &str) -> String {
    if reference.starts_with("refs/") {
        reference.to_owned()
    } else {
        format!("refs/heads/{reference}")
    }
}

fn split_push_refspec(refspec: &str) -> Result<(&str, &str), CoreError> {
    let refspec = refspec.strip_prefix('+').unwrap_or(refspec);
    let (source, destination) = refspec.split_once(':').ok_or(CoreError::InvalidArgument)?;
    if source.is_empty() || destination.is_empty() {
        return Err(CoreError::InvalidArgument);
    }
    Ok((source, destination))
}

fn sanitize_remote_url(url: &str) -> String {
    let Some(scheme) = url.find("://") else {
        return url.to_owned();
    };
    let authority_start = scheme + 3;
    let Some(at_offset) = url[authority_start..].find('@') else {
        return url.to_owned();
    };
    let at = authority_start + at_offset;
    format!("{}{}", &url[..authority_start], &url[at + 1..])
}

fn sanitize_git_error(message: &str) -> String {
    message
        .split_whitespace()
        .map(sanitize_remote_url)
        .collect::<Vec<_>>()
        .join(" ")
}

fn stable_metadata(cwd: &Path) -> Result<Value, CoreError> {
    let repository = match gix::discover(cwd) {
        Ok(repository) => repository,
        Err(_) => return Ok(Value::Null),
    };
    let root = repository
        .workdir()
        .ok_or(CoreError::InvalidArgument)?
        .to_string_lossy()
        .into_owned();
    let common_dir = repository.common_dir().to_string_lossy().into_owned();
    Ok(json!({"commonDir": common_dir, "root": root}))
}

fn worktree_shell_environment_config(
    params: &serde_json::Map<String, Value>,
) -> Result<Value, CoreError> {
    let cwd = required_path(params, "cwd")?;
    let repository = match gix::discover(cwd) {
        Ok(repository) => repository,
        Err(_) => return Ok(json!({"shellEnvironment": null})),
    };
    let path = repository.git_dir().join("codex-shell-environment.json");
    let source = match fs::read(&path) {
        Ok(source) => source,
        Err(_) => return Ok(json!({"shellEnvironment": null})),
    };
    let environment: Value = match serde_json::from_slice(&source) {
        Ok(value) => value,
        Err(_) => return Ok(json!({"shellEnvironment": null})),
    };
    let Some(object) = environment.as_object() else {
        return Ok(json!({"shellEnvironment": null}));
    };
    if object.len() != 3
        || object.get("version").and_then(Value::as_u64) != Some(1)
        || !object
            .get("set")
            .and_then(Value::as_object)
            .is_some_and(|set| set.values().all(Value::is_string))
        || !object
            .get("exclude")
            .and_then(Value::as_array)
            .is_some_and(|exclude| exclude.iter().all(Value::is_string))
    {
        return Ok(json!({"shellEnvironment": null}));
    }
    Ok(json!({"shellEnvironment": environment}))
}

fn clone_state(root: &Path) -> Result<Value, CoreError> {
    let repository = discover(root)?;
    let is_shallow = repository.common_dir().join("shallow").is_file();
    let config = repository.config_snapshot();
    let mut is_partial = config.string("extensions.partialclone").is_some();
    if !is_partial {
        for remote in repository.remote_names().iter() {
            let remote = remote
                .as_bstr()
                .to_str()
                .map_err(|_| CoreError::InvalidArgument)?;
            let promisor = format!("remote.{remote}.promisor");
            let filter = format!("remote.{remote}.partialclonefilter");
            is_partial = config.string(filter.as_str()).is_some()
                || matches!(config.try_boolean(promisor.as_str()), Some(Ok(true)));
            if is_partial {
                break;
            }
        }
    }
    Ok(json!({"isShallow": is_shallow, "isPartialClone": is_partial}))
}

fn config_string(repository: &gix::Repository, key: &str) -> Result<Option<String>, CoreError> {
    repository
        .config_snapshot()
        .string(key)
        .map(|value| utf8(value.as_ref()))
        .transpose()
}

fn config_value(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let scope = params
        .get("scope")
        .and_then(Value::as_str)
        .unwrap_or("local");
    if !matches!(scope, "local" | "worktree") {
        return Ok(json!({"value": null}));
    }
    let repository = discover(required_path(params, "root")?)?;
    let key = required_string(params, "key")?;
    Ok(json!({"value": config_string(&repository, key)?}))
}

fn git_init_repo(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let cwd = required_path(params, "cwd")?;
    fs::create_dir_all(cwd).map_err(|_| CoreError::InvalidArgument)?;
    gix::init(cwd).map_err(|_| CoreError::InvalidArgument)?;
    Ok(json!({"success": true}))
}

fn valid_local_branch_name(branch: &str) -> bool {
    !branch.is_empty()
        && branch != "@"
        && !branch.starts_with(['.', '/'])
        && !branch.ends_with(['.', '/'])
        && !branch.ends_with(".lock")
        && !branch.contains("..")
        && !branch.contains("@{")
        && !branch.contains("//")
        && !branch.bytes().any(|byte| {
            byte <= 0x20
                || byte == 0x7f
                || matches!(byte, b'~' | b'^' | b':' | b'?' | b'*' | b'[' | b'\\')
        })
        && branch.split('/').all(|component| {
            !component.is_empty() && !component.starts_with('.') && !component.ends_with(".lock")
        })
}

fn git_operation_error(error: &str, error_type: &str, command: &str) -> Value {
    json!({
        "status": "error",
        "error": error,
        "errorType": error_type,
        "conflictedPaths": [],
        "execOutput": {
            "exitCode": 1,
            "stdout": "",
            "stderr": error,
            "command": command,
        },
    })
}

fn git_create_branch(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let cwd = required_path(params, "cwd")?;
    let branch = required_string(params, "branch")?;
    if !valid_local_branch_name(branch) {
        return Ok(git_operation_error(
            "Invalid branch name",
            "invalid_branch",
            "embedded git branch",
        ));
    }
    let fail_if_exists = params
        .get("failIfExists")
        .and_then(Value::as_bool)
        .unwrap_or(true);
    let repository = discover(cwd)?;
    let reference_name = format!("refs/heads/{branch}");
    if repository
        .try_find_reference(&reference_name)
        .map_err(|_| CoreError::InvalidArgument)?
        .is_some()
    {
        if fail_if_exists {
            return Ok(git_operation_error(
                "Branch already exists",
                "branch_exists",
                "embedded git branch",
            ));
        }
        return Ok(json!({"status": "success", "branch": branch}));
    }
    let head = match repository.head_id() {
        Ok(head) => head.detach(),
        Err(_) => {
            return Ok(git_operation_error(
                "Repository HEAD has no commit",
                "unborn_head",
                "embedded git branch",
            ));
        }
    };
    if retain_ref(&repository, &reference_name, head).is_err() {
        return Ok(git_operation_error(
            "Failed to create branch",
            "create_branch_failed",
            "embedded git branch",
        ));
    }
    Ok(json!({"status": "success", "branch": branch}))
}

fn git_checkout_branch(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let cwd = required_path(params, "cwd")?;
    let branch = required_string(params, "branch")?;
    if !valid_local_branch_name(branch) {
        return Ok(git_operation_error(
            "Invalid branch name",
            "invalid_branch",
            "embedded git checkout",
        ));
    }
    let repository = discover(cwd)?;
    let counts = match git_diff::status_counts(cwd, true) {
        Ok(counts) => counts,
        Err(error) => {
            return Ok(git_operation_error(
                &error.to_string(),
                "status_failed",
                "embedded git status",
            ));
        }
    };
    if counts.staged > 0 || counts.unstaged > 0 || counts.untracked > 0 {
        return Ok(git_operation_error(
            "Working tree has uncommitted changes",
            "dirty_worktree",
            "embedded git checkout",
        ));
    }
    let Some(commit) = resolve_branch_commit(&repository, branch)? else {
        return Ok(git_operation_error(
            "Branch was not found",
            "branch_not_found",
            "embedded git checkout",
        ));
    };
    let previous_tree = repository
        .head_commit()
        .ok()
        .and_then(|commit| commit.tree_id().ok())
        .map(|tree| tree.detach());
    if set_checkout(&repository, Some(branch), commit, previous_tree).is_err() {
        return Ok(git_operation_error(
            "Failed to check out branch",
            "checkout_failed",
            "embedded git checkout",
        ));
    }
    Ok(json!({"status": "success", "branch": branch}))
}

fn git_merge_base(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let git_root = required_path(params, "gitRoot")?;
    let base_branch = required_string(params, "baseBranch")?;
    let merge_base = git_diff::merge_base_sha(git_root, base_branch)
        .ok()
        .flatten();
    Ok(json!({"mergeBaseSha": merge_base}))
}

fn config_path(repository: &gix::Repository, scope: &str) -> Result<std::path::PathBuf, CoreError> {
    match scope {
        "local" => Ok(repository.common_dir().join("config")),
        "worktree" => Ok(repository.git_dir().join("config.worktree")),
        "global" => std::env::var_os("HOME")
            .map(std::path::PathBuf::from)
            .map(|home| home.join(".gitconfig"))
            .ok_or(CoreError::InvalidArgument),
        _ => Err(CoreError::InvalidArgument),
    }
}

fn atomic_write(path: &Path, contents: &[u8]) -> Result<(), CoreError> {
    let parent = path.parent().ok_or(CoreError::InvalidArgument)?;
    fs::create_dir_all(parent).map_err(|_| CoreError::InvalidArgument)?;
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| CoreError::InvalidArgument)?
        .as_nanos();
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or(CoreError::InvalidArgument)?;
    let temporary = parent.join(format!(
        ".{file_name}.codex-{}-{nonce}.tmp",
        std::process::id()
    ));
    fs::write(&temporary, contents).map_err(|_| CoreError::InvalidArgument)?;
    if let Err(error) = fs::rename(&temporary, path) {
        let _ = fs::remove_file(&temporary);
        return Err(match error.kind() {
            _ => CoreError::InvalidArgument,
        });
    }
    Ok(())
}

fn set_config_value(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let repository = discover(required_path(params, "root")?)?;
    let key = required_string(params, "key")?;
    let parsed_key =
        gix_config::KeyRef::parse_unvalidated(key.into()).ok_or(CoreError::InvalidArgument)?;
    if parsed_key.section_name.is_empty() || parsed_key.value_name.is_empty() {
        return Err(CoreError::InvalidArgument);
    }
    let scope = params
        .get("scope")
        .and_then(Value::as_str)
        .unwrap_or("local");
    let path = config_path(&repository, scope)?;
    let existing = match fs::read_to_string(&path) {
        Ok(contents) => contents,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(_) => return Err(CoreError::InvalidArgument),
    };
    let mut config =
        gix_config::File::try_from(existing.as_str()).map_err(|_| CoreError::InvalidArgument)?;
    match params.get("value") {
        Some(Value::String(value)) => {
            config
                .set_raw_value(&key, value.as_str())
                .map_err(|_| CoreError::InvalidArgument)?;
        }
        None | Some(Value::Null) => {
            if let Ok(mut section) =
                config.section_mut(parsed_key.section_name, parsed_key.subsection_name)
            {
                section.remove(parsed_key.value_name);
            }
        }
        _ => return Err(CoreError::InvalidArgument),
    }
    let mut output = Vec::new();
    config
        .write_to(&mut output)
        .map_err(|_| CoreError::InvalidArgument)?;
    atomic_write(&path, &output)?;
    Ok(json!({"success": true}))
}

fn staged_tree(repository: &gix::Repository) -> Result<gix::ObjectId, CoreError> {
    let index = repository
        .index_or_load_from_head_or_empty()
        .map_err(|_| CoreError::InvalidArgument)?;
    if index
        .entries()
        .iter()
        .any(|entry| entry.stage() != gix::index::entry::Stage::Unconflicted)
    {
        return Err(CoreError::InvalidArgument);
    }
    let mut editor = repository
        .empty_tree()
        .edit()
        .map_err(|_| CoreError::InvalidArgument)?;
    for entry in index.entries() {
        if entry.mode.is_sparse() {
            return Err(CoreError::InvalidArgument);
        }
        let mode = entry
            .mode
            .to_tree_entry_mode()
            .ok_or(CoreError::InvalidArgument)?;
        editor
            .upsert(entry.path(&index).to_owned(), mode.kind(), entry.id)
            .map_err(|_| CoreError::InvalidArgument)?;
    }
    editor
        .write()
        .map(|id| id.detach())
        .map_err(|_| CoreError::InvalidArgument)
}

fn worktree_blob(
    repository: &gix::Repository,
    path: &Path,
) -> Result<(gix::object::tree::EntryKind, gix::ObjectId), CoreError> {
    let metadata = fs::symlink_metadata(path).map_err(|_| CoreError::InvalidArgument)?;
    let (kind, data) = if metadata.file_type().is_symlink() {
        let target = fs::read_link(path).map_err(|_| CoreError::InvalidArgument)?;
        (
            gix::object::tree::EntryKind::Link,
            target.as_os_str().as_bytes().to_vec(),
        )
    } else if metadata.file_type().is_file() {
        let kind = if metadata.permissions().mode() & 0o111 == 0 {
            gix::object::tree::EntryKind::Blob
        } else {
            gix::object::tree::EntryKind::BlobExecutable
        };
        (
            kind,
            fs::read(path).map_err(|_| CoreError::InvalidArgument)?,
        )
    } else {
        return Err(CoreError::InvalidArgument);
    };
    let id = repository
        .write_blob(data)
        .map_err(|_| CoreError::InvalidArgument)?
        .detach();
    Ok((kind, id))
}

fn add_untracked_to_editor(
    repository: &gix::Repository,
    workdir: &Path,
    relative_directory: &Path,
    tracked: &BTreeSet<gix::bstr::BString>,
    excludes: &mut gix::AttributeStack<'_>,
    editor: &mut gix::object::tree::Editor<'_>,
) -> Result<(), CoreError> {
    let directory = workdir.join(relative_directory);
    let mut children = fs::read_dir(&directory)
        .map_err(|_| CoreError::InvalidArgument)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|_| CoreError::InvalidArgument)?;
    children.sort_by(|left, right| {
        left.file_name()
            .as_bytes()
            .cmp(right.file_name().as_bytes())
    });
    for child in children {
        let relative = relative_directory.join(child.file_name());
        if relative_directory.as_os_str().is_empty() && relative.as_os_str() == ".git" {
            continue;
        }
        let metadata =
            fs::symlink_metadata(child.path()).map_err(|_| CoreError::InvalidArgument)?;
        let ignore_mode = if metadata.file_type().is_dir() {
            gix::index::entry::Mode::DIR
        } else if metadata.file_type().is_symlink() {
            gix::index::entry::Mode::SYMLINK
        } else {
            gix::index::entry::Mode::FILE
        };
        if excludes
            .at_path(&relative, Some(ignore_mode))
            .map_err(|_| CoreError::InvalidArgument)?
            .is_excluded()
        {
            continue;
        }
        if metadata.file_type().is_dir() {
            if child.path().join(".git").exists() {
                return Err(CoreError::InvalidArgument);
            }
            add_untracked_to_editor(repository, workdir, &relative, tracked, excludes, editor)?;
            continue;
        }
        let relative_bytes = gix::bstr::BString::from(relative.as_os_str().as_bytes().to_vec());
        if tracked.contains(&relative_bytes) {
            continue;
        }
        let (kind, id) = worktree_blob(repository, &child.path())?;
        editor
            .upsert(relative_bytes, kind, id)
            .map_err(|_| CoreError::InvalidArgument)?;
    }
    Ok(())
}

fn stage_worktree(repository: &gix::Repository) -> Result<gix::ObjectId, CoreError> {
    working_tree(repository, true)
}

fn working_tree(
    repository: &gix::Repository,
    update_index: bool,
) -> Result<gix::ObjectId, CoreError> {
    let workdir = repository
        .workdir()
        .ok_or(CoreError::InvalidArgument)?
        .to_owned();
    let index = repository
        .index_or_load_from_head_or_empty()
        .map_err(|_| CoreError::InvalidArgument)?;
    if index
        .entries()
        .iter()
        .any(|entry| entry.stage() != gix::index::entry::Stage::Unconflicted)
    {
        return Err(CoreError::InvalidArgument);
    }
    let tracked = index
        .entries()
        .iter()
        .map(|entry| entry.path(&index).to_owned())
        .collect::<BTreeSet<_>>();
    let mut editor = repository
        .empty_tree()
        .edit()
        .map_err(|_| CoreError::InvalidArgument)?;
    for entry in index.entries() {
        if entry.mode.is_sparse() {
            return Err(CoreError::InvalidArgument);
        }
        let relative = entry.path(&index);
        let path = workdir.join(gix::path::from_bstr(relative).as_ref());
        if entry.mode == gix::index::entry::Mode::COMMIT {
            editor
                .upsert(
                    relative.to_owned(),
                    gix::object::tree::EntryKind::Commit,
                    entry.id,
                )
                .map_err(|_| CoreError::InvalidArgument)?;
        } else if path.exists() || fs::symlink_metadata(&path).is_ok() {
            let (kind, id) = worktree_blob(repository, &path)?;
            editor
                .upsert(relative.to_owned(), kind, id)
                .map_err(|_| CoreError::InvalidArgument)?;
        }
    }
    let worktree = repository.worktree().ok_or(CoreError::InvalidArgument)?;
    let mut excludes = worktree
        .excludes(None)
        .map_err(|_| CoreError::InvalidArgument)?;
    add_untracked_to_editor(
        repository,
        &workdir,
        Path::new(""),
        &tracked,
        &mut excludes,
        &mut editor,
    )?;
    let tree = editor
        .write()
        .map_err(|_| CoreError::InvalidArgument)?
        .detach();
    if update_index {
        let mut staged_index = repository
            .index_from_tree(&tree)
            .map_err(|_| CoreError::InvalidArgument)?;
        staged_index
            .write(gix::index::write::Options::default())
            .map_err(|_| CoreError::InvalidArgument)?;
    }
    Ok(tree)
}

fn hash256(value: &str) -> String {
    Sha256::digest(value.as_bytes())
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn timestamp_ms() -> Result<u128, CoreError> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis())
        .map_err(|_| CoreError::InvalidArgument)
}

fn retain_ref(
    repository: &gix::Repository,
    name: &str,
    target: gix::ObjectId,
) -> Result<(), CoreError> {
    repository
        .reference(
            name,
            target,
            gix::refs::transaction::PreviousValue::Any,
            "codex turn diff snapshot",
        )
        .map(|_| ())
        .map_err(|_| CoreError::InvalidArgument)
}

fn delete_ref(repository: &gix::Repository, name: &str) {
    if let Ok(Some(reference)) = repository.try_find_reference(name) {
        let _ = reference.delete();
    }
}

fn successful_tree_diff(diff: String) -> Value {
    json!({
        "type": "success",
        "unifiedDiffBytes": diff.len(),
        "unifiedDiff": diff,
    })
}

fn tree_diff_value(root: &Path, base: &str, head: &str) -> Result<Value, CoreError> {
    match git_diff::tree_diff(root, base, head) {
        Ok(diff) => Ok(successful_tree_diff(diff)),
        Err(_) => Ok(json!({"type": "error", "error": {"type": "unknown"}})),
    }
}

fn latest_turn_checkpoint(
    repository: &gix::Repository,
    prefix: &str,
    now_ms: u128,
) -> Result<Option<gix::ObjectId>, CoreError> {
    let directory = repository.common_dir().join(prefix);
    let mut candidates = Vec::new();
    let Ok(entries) = fs::read_dir(&directory) else {
        return Ok(None);
    };
    for entry in entries.flatten() {
        let Some(timestamp) = entry
            .file_name()
            .to_str()
            .and_then(|value| value.parse::<u128>().ok())
        else {
            continue;
        };
        if now_ms.saturating_sub(timestamp) > 7 * 24 * 60 * 60 * 1_000 {
            continue;
        }
        let Ok(children) = fs::read_dir(entry.path()) else {
            continue;
        };
        for child in children.flatten() {
            let Ok(contents) = fs::read_to_string(child.path()) else {
                continue;
            };
            let Ok(id) = gix::ObjectId::from_hex(contents.trim().as_bytes()) else {
                continue;
            };
            candidates.push((timestamp, id));
        }
    }
    candidates.sort_by(|left, right| right.0.cmp(&left.0));
    Ok(candidates.first().map(|candidate| candidate.1))
}

fn turn_diff_capture_start(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let cwd = required_path(params, "cwd")?;
    let checkpoint_key = required_string(params, "checkpointKey")?;
    let turn_id = required_string(params, "turnId")?;
    let repository = match discover(cwd) {
        Ok(repository) => repository,
        Err(_) => return Ok(Value::Null),
    };
    let root = repository
        .workdir()
        .ok_or(CoreError::InvalidArgument)?
        .to_owned();
    let base_tree = working_tree(&repository, false)?;
    let timestamp = timestamp_ms()?;
    let nonce = format!("{}-{:x}", std::process::id(), timestamp);
    let ref_prefix = format!("refs/codex/turn-diffs/captures/{timestamp}/{nonce}");
    let checkpoint_scope = format!(
        "refs/codex/turn-diffs/checkpoints/{}",
        hash256(checkpoint_key)
    );
    let checkpoint_ref = format!("{checkpoint_scope}/{}", hash256(turn_id));
    let base_turn_tree = params
        .get("baseTurnId")
        .and_then(Value::as_str)
        .map(|base_turn_id| {
            latest_turn_checkpoint(
                &repository,
                &format!("{checkpoint_scope}/{}", hash256(base_turn_id)),
                timestamp,
            )
        })
        .transpose()?
        .flatten();
    retain_ref(&repository, &format!("{ref_prefix}/base"), base_tree)?;
    let (session_start_commit, session_start_diff) =
        if params.get("baseTurnId").and_then(Value::as_str).is_none() {
            match repository.head_id() {
                Ok(head) => {
                    let head = head.detach();
                    (
                        Value::String(head.to_string()),
                        tree_diff_value(&root, &head.to_string(), &base_tree.to_string())?,
                    )
                }
                Err(_) => (Value::Null, Value::Null),
            }
        } else {
            (Value::Null, Value::Null)
        };
    Ok(json!({
        "baseTreeSha": base_tree.to_string(),
        "baseTurnHeadTreeSha": base_turn_tree.map(|id| id.to_string()),
        "sessionStartCommitSha": session_start_commit,
        "sessionStartDiff": session_start_diff,
        "checkpointRefPrefix": checkpoint_ref,
        "checkpointScopeRefPrefix": checkpoint_scope,
        "refPrefix": ref_prefix,
        "root": root,
    }))
}

fn turn_diff_capture_complete(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let capture = params
        .get("capture")
        .and_then(Value::as_object)
        .ok_or(CoreError::InvalidArgument)?;
    let root = required_path(capture, "root")?;
    let base_tree = required_string(capture, "baseTreeSha")?;
    let ref_prefix = required_string(capture, "refPrefix")?;
    let checkpoint_ref = required_string(capture, "checkpointRefPrefix")?;
    let repository = discover(root)?;
    let head_tree = working_tree(&repository, false)?;
    retain_ref(&repository, &format!("{ref_prefix}/head"), head_tree)?;
    let diff = tree_diff_value(root, base_tree, &head_tree.to_string())?;
    let between_turn_diff = match capture.get("baseTurnHeadTreeSha").and_then(Value::as_str) {
        Some(base_turn_tree) => tree_diff_value(root, base_turn_tree, base_tree)?,
        None => Value::Null,
    };
    if params
        .get("retainCheckpoint")
        .and_then(Value::as_bool)
        .unwrap_or(false)
        && diff.get("type").and_then(Value::as_str) == Some("success")
    {
        let timestamp = timestamp_ms()?;
        retain_ref(
            &repository,
            &format!(
                "{checkpoint_ref}/{timestamp}/{}-{timestamp:x}",
                std::process::id()
            ),
            head_tree,
        )?;
    }
    delete_ref(&repository, &format!("{ref_prefix}/head"));
    delete_ref(&repository, &format!("{ref_prefix}/base"));
    Ok(json!({
        "baseTreeSha": base_tree,
        "baseTurnHeadTreeSha": capture.get("baseTurnHeadTreeSha").cloned().unwrap_or(Value::Null),
        "betweenTurnDiff": between_turn_diff,
        "sessionStartCommitSha": capture.get("sessionStartCommitSha").cloned().unwrap_or(Value::Null),
        "sessionStartDiff": capture.get("sessionStartDiff").cloned().unwrap_or(Value::Null),
        "headTreeSha": head_tree.to_string(),
        "diff": diff,
    }))
}

fn resolve_tree(repository: &gix::Repository, reference: &str) -> Result<gix::ObjectId, CoreError> {
    let object = repository
        .rev_parse_single(reference)
        .map_err(|_| CoreError::InvalidArgument)?
        .object()
        .map_err(|_| CoreError::InvalidArgument)?;
    match object.kind {
        gix::object::Kind::Tree => Ok(object.id),
        gix::object::Kind::Commit => object
            .try_into_commit()
            .map_err(|_| CoreError::InvalidArgument)?
            .tree_id()
            .map(|id| id.detach())
            .map_err(|_| CoreError::InvalidArgument),
        _ => Err(CoreError::InvalidArgument),
    }
}

fn reference_for_checkout(
    repository: &gix::Repository,
    requested_branch: Option<&str>,
) -> Result<String, CoreError> {
    if let Some(branch) = requested_branch {
        return Ok(format!("refs/heads/{branch}"));
    }
    let head = repository.head().map_err(|_| CoreError::InvalidArgument)?;
    Ok(head
        .referent_name()
        .map(|name| name.as_bstr().to_string())
        .unwrap_or_else(|| "HEAD".to_owned()))
}

fn remove_worktree_path(path: &Path) -> Result<(), CoreError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_dir() => {
            fs::remove_dir_all(path).map_err(|_| CoreError::InvalidArgument)
        }
        Ok(_) => fs::remove_file(path).map_err(|_| CoreError::InvalidArgument),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(_) => Err(CoreError::InvalidArgument),
    }
}

fn restore_tree_to_worktree(
    repository: &gix::Repository,
    tree: gix::ObjectId,
    previous_tree: Option<gix::ObjectId>,
) -> Result<(), CoreError> {
    let workdir = repository
        .workdir()
        .ok_or(CoreError::InvalidArgument)?
        .to_owned();
    let restored = repository
        .index_from_tree(&tree)
        .map_err(|_| CoreError::InvalidArgument)?;
    let restored_paths = restored
        .entries()
        .iter()
        .map(|entry| entry.path(&restored).to_owned())
        .collect::<BTreeSet<_>>();
    if let Some(previous_tree) = previous_tree {
        let previous = repository
            .index_from_tree(&previous_tree)
            .map_err(|_| CoreError::InvalidArgument)?;
        for entry in previous.entries() {
            if !restored_paths.contains(entry.path(&previous)) {
                let path = workdir.join(gix::path::from_bstr(entry.path(&previous)).as_ref());
                remove_worktree_path(&path)?;
            }
        }
    }
    for entry in restored.entries() {
        if entry.mode.is_sparse() || entry.mode == gix::index::entry::Mode::COMMIT {
            return Err(CoreError::UnsupportedCommand);
        }
        let path = workdir.join(gix::path::from_bstr(entry.path(&restored)).as_ref());
        if fs::symlink_metadata(&path).is_ok() {
            remove_worktree_path(&path)?;
        }
        let parent = path.parent().ok_or(CoreError::InvalidArgument)?;
        fs::create_dir_all(parent).map_err(|_| CoreError::InvalidArgument)?;
        let blob = repository
            .find_blob(entry.id)
            .map_err(|_| CoreError::InvalidArgument)?;
        if entry.mode == gix::index::entry::Mode::SYMLINK {
            std::os::unix::fs::symlink(std::ffi::OsStr::from_bytes(&blob.data), &path)
                .map_err(|_| CoreError::InvalidArgument)?;
        } else {
            fs::write(&path, &blob.data).map_err(|_| CoreError::InvalidArgument)?;
            let mode = if entry.mode == gix::index::entry::Mode::FILE_EXECUTABLE {
                0o755
            } else {
                0o644
            };
            fs::set_permissions(&path, fs::Permissions::from_mode(mode))
                .map_err(|_| CoreError::InvalidArgument)?;
        }
    }
    Ok(())
}

fn reset_index_to_tree(repository: &gix::Repository, tree: gix::ObjectId) -> Result<(), CoreError> {
    let mut index = repository
        .index_from_tree(&tree)
        .map_err(|_| CoreError::InvalidArgument)?;
    index
        .write(gix::index::write::Options::default())
        .map_err(|_| CoreError::InvalidArgument)
}

fn overwrite_command_error(message: impl Into<String>, command: &str) -> Value {
    let message = message.into();
    json!({
        "status": "command-error",
        "execOutput": {
            "exitCode": 1,
            "stdout": "",
            "stderr": message,
            "command": command,
        },
    })
}

fn overwrite_repository(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let git_root = required_path(params, "gitRoot")?;
    let target_root = params
        .get("targetRoot")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(Path::new);
    let branch_name = required_string(params, "branchName")?;
    let head_commit_sha = required_string(params, "headCommitSha")?;
    let requested_tree_sha = params
        .get("treeSha")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty());
    let target_branch = params
        .get("targetCurrentBranch")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty());
    let source = discover(git_root)?;
    let head_commit = match source.rev_parse_single(head_commit_sha) {
        Ok(spec) => match spec.object() {
            Ok(object) => match object.peel_to_kind(gix::object::Kind::Commit) {
                Ok(commit) => commit.id,
                Err(error) => {
                    return Ok(overwrite_command_error(
                        error.to_string(),
                        "embedded git rev-parse",
                    ));
                }
            },
            Err(error) => {
                return Ok(overwrite_command_error(
                    error.to_string(),
                    "embedded git rev-parse",
                ));
            }
        },
        Err(error) => {
            return Ok(overwrite_command_error(
                error.to_string(),
                "embedded git rev-parse",
            ));
        }
    };
    let head_tree = source
        .find_commit(head_commit)
        .map_err(|_| CoreError::InvalidArgument)?
        .tree_id()
        .map_err(|_| CoreError::InvalidArgument)?
        .detach();
    let requested_tree = requested_tree_sha
        .map(|reference| resolve_tree(&source, reference))
        .transpose()?;
    let should_create_synthetic = requested_tree.is_some_and(|tree| tree != head_tree)
        && (target_root.is_none() || target_branch.is_none() || target_branch == Some(branch_name));
    let mut commit_to_apply = head_commit;
    if should_create_synthetic {
        let tree = requested_tree.ok_or(CoreError::InvalidArgument)?;
        let synthetic =
            match source.new_commit("Codex synchronized working tree", tree, [head_commit]) {
                Ok(commit) => commit.id,
                Err(error) => {
                    return Ok(overwrite_command_error(
                        error.to_string(),
                        "embedded git commit-tree",
                    ));
                }
            };
        commit_to_apply = synthetic;
        let old_tree = source
            .head_commit()
            .ok()
            .and_then(|commit| commit.tree_id().ok())
            .map(|id| id.detach());
        let reference = reference_for_checkout(&source, None)?;
        retain_ref(&source, &reference, synthetic)?;
        if let Err(error) = restore_tree_to_worktree(&source, tree, old_tree)
            .and_then(|_| reset_index_to_tree(&source, tree))
        {
            return Ok(overwrite_command_error(
                format!("{error:?}"),
                "embedded git reset --hard",
            ));
        }
    }
    let Some(target_root) = target_root else {
        if let Err(error) = retain_ref(
            &source,
            &format!("refs/heads/{branch_name}"),
            commit_to_apply,
        ) {
            return Ok(overwrite_command_error(
                format!("{error:?}"),
                "embedded git branch -f",
            ));
        }
        return Ok(json!({"status": "success"}));
    };

    let target = discover(target_root)?;
    let old_tree = target
        .head_commit()
        .ok()
        .and_then(|commit| commit.tree_id().ok())
        .map(|id| id.detach());
    let reference = reference_for_checkout(&target, target_branch)?;
    if let Err(error) = retain_ref(&target, &reference, commit_to_apply) {
        return Ok(overwrite_command_error(
            format!("{error:?}"),
            "embedded git update-ref",
        ));
    }
    if let Err(error) = reset_index_to_tree(&target, head_tree) {
        return Ok(overwrite_command_error(
            format!("{error:?}"),
            "embedded git reset --mixed",
        ));
    }
    if let Err(error) =
        restore_tree_to_worktree(&target, requested_tree.unwrap_or(head_tree), old_tree)
    {
        return Ok(overwrite_command_error(
            format!("{error:?}"),
            "embedded git restore",
        ));
    }
    Ok(json!({"status": "success"}))
}

fn current_branch_name(repository: &gix::Repository) -> Result<Option<String>, CoreError> {
    let head = repository.head().map_err(|_| CoreError::InvalidArgument)?;
    Ok(head.referent_name().and_then(|name| {
        name.as_bstr()
            .to_str()
            .ok()
            .and_then(|name| name.strip_prefix("refs/heads/"))
            .map(str::to_owned)
    }))
}

fn set_checkout(
    repository: &gix::Repository,
    branch: Option<&str>,
    commit: gix::ObjectId,
    previous_tree: Option<gix::ObjectId>,
) -> Result<(), CoreError> {
    let tree = repository
        .find_commit(commit)
        .map_err(|_| CoreError::InvalidArgument)?
        .tree_id()
        .map_err(|_| CoreError::InvalidArgument)?
        .detach();
    if let Some(branch) = branch {
        retain_ref(repository, &format!("refs/heads/{branch}"), commit)?;
        atomic_write(
            &repository.git_dir().join("HEAD"),
            format!("ref: refs/heads/{branch}\n").as_bytes(),
        )?;
    } else {
        atomic_write(
            &repository.git_dir().join("HEAD"),
            format!("{commit}\n").as_bytes(),
        )?;
    }
    restore_tree_to_worktree(repository, tree, previous_tree)?;
    reset_index_to_tree(repository, tree)
}

fn handoff_error(code: &str, message: &str, rollback_errors: Vec<&str>) -> Value {
    json!({
        "status": "error",
        "error": code,
        "message": message,
        "rollbackErrors": rollback_errors,
        "warnings": [],
    })
}

fn tree_patch(
    root: &Path,
    base: gix::ObjectId,
    snapshot: gix::ObjectId,
) -> Result<String, CoreError> {
    match git_diff::tree_diff(root, &base.to_string(), &snapshot.to_string()) {
        Ok(diff) => Ok(diff),
        Err(_) => Err(CoreError::InvalidArgument),
    }
}

fn apply_unstaged_patch(root: &Path, diff: String) -> Result<bool, CoreError> {
    if diff.is_empty() {
        return Ok(true);
    }
    let mut patch_params = serde_json::Map::new();
    patch_params.insert(
        "cwd".to_owned(),
        Value::String(root.to_string_lossy().into_owned()),
    );
    patch_params.insert("diff".to_owned(), Value::String(diff));
    patch_params.insert("atomic".to_owned(), Value::Bool(true));
    patch_params.insert("target".to_owned(), Value::String("unstaged".to_owned()));
    Ok(apply_patch(&patch_params)?["status"] == "success")
}

fn branch_commit(repository: &gix::Repository, branch: &str) -> Result<gix::ObjectId, CoreError> {
    let reference = format!("refs/heads/{branch}");
    repository
        .rev_parse_single(reference.as_str())
        .map_err(|_| CoreError::InvalidArgument)?
        .object()
        .map_err(|_| CoreError::InvalidArgument)?
        .peel_to_kind(gix::object::Kind::Commit)
        .map(|commit| commit.id)
        .map_err(|_| CoreError::InvalidArgument)
}

fn move_thread_to_local(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let source_cwd = required_path(params, "sourceWorktreeCwd")?;
    let _source_root = required_path(params, "sourceWorktreeRoot")?;
    let local_root = required_path(params, "localGitRoot")?;
    let source_branch = required_string(params, "sourceBranch")?.trim();
    if source_branch.is_empty() {
        return Ok(handoff_error(
            "invalid-params",
            "Missing source branch",
            vec![],
        ));
    }
    let source = discover(source_cwd)?;
    let local = discover(local_root)?;
    let source_original_branch = current_branch_name(&source)?;
    let local_original_branch = current_branch_name(&local)?;
    let source_head = source
        .head_id()
        .map_err(|_| CoreError::InvalidArgument)?
        .detach();
    let source_head_tree = source
        .find_commit(source_head)
        .map_err(|_| CoreError::InvalidArgument)?
        .tree_id()
        .map_err(|_| CoreError::InvalidArgument)?
        .detach();
    let source_snapshot = working_tree(&source, false)?;
    let source_diff = tree_patch(source_cwd, source_head_tree, source_snapshot)?;
    let local_head = local
        .head_id()
        .map_err(|_| CoreError::InvalidArgument)?
        .detach();
    let local_head_tree = local
        .find_commit(local_head)
        .map_err(|_| CoreError::InvalidArgument)?
        .tree_id()
        .map_err(|_| CoreError::InvalidArgument)?
        .detach();
    let counts =
        git_diff::status_counts(local_root, true).map_err(|_| CoreError::InvalidArgument)?;
    if counts.staged != 0 || counts.unstaged != 0 || counts.untracked != 0 {
        return Ok(handoff_error(
            "local-destination-has-tracked-changes",
            "You have uncommitted local changes. Commit or stash them first.",
            vec![],
        ));
    }
    if let Some(mut existing) = local
        .try_find_reference(format!("refs/heads/{source_branch}").as_str())
        .map_err(|_| CoreError::InvalidArgument)?
    {
        if existing
            .peel_to_commit()
            .map_err(|_| CoreError::InvalidArgument)?
            .id()
            .detach()
            != source_head
        {
            return Ok(handoff_error(
                "local-branch-head-mismatch",
                "Destination branch does not match the source worktree HEAD",
                vec![],
            ));
        }
    }
    set_checkout(&source, None, source_head, Some(source_snapshot))?;
    if set_checkout(
        &local,
        Some(source_branch),
        source_head,
        Some(local_head_tree),
    )
    .is_err()
    {
        let _ = set_checkout(
            &source,
            source_original_branch.as_deref(),
            source_head,
            Some(source_head_tree),
        );
        return Ok(handoff_error(
            "checkout-local-failed",
            "Failed to check out local branch",
            vec!["restore-source-failed"],
        ));
    }
    if !apply_unstaged_patch(local_root, source_diff)? {
        let _ = set_checkout(
            &local,
            local_original_branch.as_deref(),
            local_head,
            Some(source_snapshot),
        );
        let _ = set_checkout(
            &source,
            source_original_branch.as_deref(),
            source_head,
            Some(source_head_tree),
        )
        .and_then(|_| restore_tree_to_worktree(&source, source_snapshot, Some(source_head_tree)));
        return Ok(handoff_error(
            "apply-source-stash-failed",
            "Failed to apply source changes",
            vec![],
        ));
    }
    Ok(json!({
        "status": "success",
        "warnings": [],
        "_progress": [
            {"step": "stash-source-changes", "status": if source_snapshot == source_head_tree { "skipped" } else { "completed" }},
            {"step": "detach-worktree-branch", "status": "completed"},
            {"step": "checkout-local-branch", "status": if local_original_branch.as_deref() == Some(source_branch) { "skipped" } else { "completed" }},
            {"step": "apply-changes-to-local", "status": if source_snapshot == source_head_tree { "skipped" } else { "completed" }},
        ],
    }))
}

fn move_thread_to_worktree(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let local_cwd = required_path(params, "localCwd")?;
    let worktree_root = required_path(params, "worktreeWorkspaceRoot")?;
    let _worktree_git_root = required_path(params, "worktreeGitRoot")?;
    let source_branch = required_string(params, "sourceBranch")?.trim();
    let target_branch = params
        .get("worktreeCheckoutBranch")
        .and_then(Value::as_str)
        .unwrap_or(source_branch)
        .trim();
    let default_branch = params
        .get("defaultBranch")
        .and_then(Value::as_str)
        .map(str::trim);
    let stash_target = params
        .get("stashTargetWorktree")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    if source_branch.is_empty() {
        return Ok(handoff_error(
            "invalid-params",
            "Missing source branch",
            vec![],
        ));
    }
    if target_branch.is_empty() {
        return Ok(handoff_error(
            "invalid-params",
            "Missing worktree checkout branch",
            vec![],
        ));
    }
    if default_branch == Some(target_branch) {
        return Ok(handoff_error(
            "default-branch-blocked",
            "Move to worktree is not available on the default branch",
            vec![],
        ));
    }

    let local = discover(local_cwd)?;
    let target = discover(worktree_root)?;
    let Some(local_original_branch) = current_branch_name(&local)? else {
        return Ok(handoff_error(
            "local-not-on-branch",
            "Local repository must be on a branch to move to a worktree",
            vec![],
        ));
    };
    let local_head = local
        .head_id()
        .map_err(|_| CoreError::InvalidArgument)?
        .detach();
    let local_head_tree = local
        .find_commit(local_head)
        .map_err(|_| CoreError::InvalidArgument)?
        .tree_id()
        .map_err(|_| CoreError::InvalidArgument)?
        .detach();
    let local_snapshot = working_tree(&local, false)?;
    let moves_source = local_original_branch == source_branch;
    let source_diff = if moves_source {
        tree_patch(local_cwd, local_head_tree, local_snapshot)?
    } else {
        String::new()
    };
    let local_checkout = if moves_source {
        let branch = params
            .get("localCheckoutBranch")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|branch| !branch.is_empty());
        let Some(branch) = branch else {
            return Ok(handoff_error(
                "invalid-params",
                "Missing local checkout branch",
                vec![],
            ));
        };
        Some((branch, branch_commit(&local, branch)?))
    } else {
        None
    };

    let target_original_branch = current_branch_name(&target)?;
    let target_head = target
        .head_id()
        .map_err(|_| CoreError::InvalidArgument)?
        .detach();
    let target_head_tree = target
        .find_commit(target_head)
        .map_err(|_| CoreError::InvalidArgument)?
        .tree_id()
        .map_err(|_| CoreError::InvalidArgument)?
        .detach();
    let target_snapshot = working_tree(&target, false)?;
    let target_diff = tree_patch(worktree_root, target_head_tree, target_snapshot)?;
    let target_commit = branch_commit(&target, target_branch)?;
    let target_commit_tree = target
        .find_commit(target_commit)
        .map_err(|_| CoreError::InvalidArgument)?
        .tree_id()
        .map_err(|_| CoreError::InvalidArgument)?
        .detach();

    if let Some((branch, commit)) = local_checkout {
        if set_checkout(&local, Some(branch), commit, Some(local_snapshot)).is_err() {
            return Ok(handoff_error(
                "checkout-local-failed",
                "Failed to check out local branch",
                vec![],
            ));
        }
    }

    if set_checkout(
        &target,
        Some(target_branch),
        target_commit,
        Some(target_snapshot),
    )
    .is_err()
    {
        let mut rollback_errors = Vec::new();
        if moves_source
            && set_checkout(
                &local,
                Some(&local_original_branch),
                local_head,
                working_tree(&local, false).ok(),
            )
            .and_then(|_| restore_tree_to_worktree(&local, local_snapshot, Some(local_head_tree)))
            .is_err()
        {
            rollback_errors.push("restore-local-failed");
        }
        return Ok(handoff_error(
            "checkout-worktree-failed",
            "Failed to check out worktree branch",
            rollback_errors,
        ));
    }

    let restore_all = || {
        let mut errors = Vec::new();
        if set_checkout(
            &target,
            target_original_branch.as_deref(),
            target_head,
            working_tree(&target, false)
                .ok()
                .or(Some(target_commit_tree)),
        )
        .and_then(|_| restore_tree_to_worktree(&target, target_snapshot, Some(target_head_tree)))
        .is_err()
        {
            errors.push("restore-target-worktree-failed");
        }
        if moves_source
            && set_checkout(
                &local,
                Some(&local_original_branch),
                local_head,
                working_tree(&local, false).ok(),
            )
            .and_then(|_| restore_tree_to_worktree(&local, local_snapshot, Some(local_head_tree)))
            .is_err()
        {
            errors.push("restore-local-failed");
        }
        errors
    };

    if !apply_unstaged_patch(worktree_root, target_diff)? {
        return Ok(handoff_error(
            "checkout-worktree-failed",
            "Failed to restore target worktree changes",
            restore_all(),
        ));
    }
    if !apply_unstaged_patch(worktree_root, source_diff)? {
        return Ok(handoff_error(
            "apply-source-stash-failed",
            "Failed to apply source changes",
            restore_all(),
        ));
    }

    let target_dirty = target_snapshot != target_head_tree;
    Ok(json!({
        "status": "success",
        "warnings": if stash_target && target_dirty {
            vec!["stashed-target-worktree-changes"]
        } else {
            Vec::<&str>::new()
        },
        "_progress": [
            {"step": "stash-source-changes", "status": if moves_source && local_snapshot != local_head_tree { "completed" } else { "skipped" }},
            {"step": "checkout-local-branch", "status": if moves_source { "completed" } else { "skipped" }},
            {"step": "stash-target-worktree-changes", "status": if stash_target && target_dirty { "completed" } else { "skipped" }},
            {"step": "checkout-worktree-branch", "status": "completed"},
            {"step": "apply-changes-to-worktree", "status": if moves_source && local_snapshot != local_head_tree { "completed" } else { "skipped" }},
        ],
    }))
}

fn copy_reachable_objects(
    source: &gix::Repository,
    destination: &gix::Repository,
    roots: impl IntoIterator<Item = gix::ObjectId>,
) -> Result<(), CoreError> {
    if source.object_hash() != destination.object_hash() {
        return Err(CoreError::UnsupportedCommand);
    }
    let mut pending = roots.into_iter().collect::<Vec<_>>();
    let mut visited = BTreeSet::new();
    while let Some(id) = pending.pop() {
        if !visited.insert(id) {
            continue;
        }
        if destination
            .try_find_object(id)
            .map_err(|_| CoreError::InvalidArgument)?
            .is_some()
        {
            continue;
        }
        let source_object = source
            .find_object(id)
            .map_err(|_| CoreError::InvalidArgument)?;
        let object = gix::objs::Data::new(source_object.kind, &source_object.data)
            .decode()
            .map_err(|_| CoreError::InvalidArgument)?
            .into_owned()
            .map_err(|_| CoreError::InvalidArgument)?;
        match &object {
            gix::objs::Object::Commit(commit) => {
                pending.push(commit.tree);
                pending.extend(commit.parents.iter().copied());
            }
            gix::objs::Object::Tree(tree) => {
                pending.extend(
                    tree.entries
                        .iter()
                        .filter(|entry| entry.mode.value() != 0o160000)
                        .map(|entry| entry.oid),
                );
            }
            gix::objs::Object::Tag(tag) => pending.push(tag.target),
            gix::objs::Object::Blob(_) => {}
        }
        destination
            .write_object(object)
            .map_err(|_| CoreError::InvalidArgument)?;
    }
    Ok(())
}

fn host_handoff_error(code: &str, message: &str) -> Value {
    json!({"status": "error", "error": code, "message": message})
}

fn move_thread_to_host_worktree(
    params: &serde_json::Map<String, Value>,
) -> Result<Value, CoreError> {
    let source_cwd = required_path(params, "sourceCwd")?;
    let source_branch = required_string(params, "sourceBranch")?.trim();
    let source_rollout = required_path(params, "sourceRolloutPath")?;
    let destination_workspace = required_path(params, "destinationWorkspaceRoot")?;
    let destination_git_root = params
        .get("destinationWorktreeGitRoot")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(Path::new);
    let destination_worktree_root = params
        .get("destinationWorktreeWorkspaceRoot")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(Path::new);
    if source_branch.is_empty() || !source_rollout.is_file() {
        return Ok(host_handoff_error(
            "invalid-params",
            if source_branch.is_empty() {
                "Missing source branch"
            } else {
                "Missing source rollout path"
            },
        ));
    }
    if destination_git_root.is_some() != destination_worktree_root.is_some() {
        return Ok(host_handoff_error(
            "invalid-params",
            "Destination worktree roots must be provided together",
        ));
    }

    let source = discover(source_cwd)?;
    let destination = discover(destination_workspace)?;
    let source_head = source
        .head_id()
        .map_err(|_| CoreError::InvalidArgument)?
        .detach();
    let source_head_tree = source
        .find_commit(source_head)
        .map_err(|_| CoreError::InvalidArgument)?
        .tree_id()
        .map_err(|_| CoreError::InvalidArgument)?
        .detach();
    let source_snapshot = working_tree(&source, false)?;
    if destination_worktree_root.is_none()
        && destination
            .try_find_reference(format!("refs/heads/{source_branch}").as_str())
            .map_err(|_| CoreError::InvalidArgument)?
            .is_some_and(|mut reference| {
                reference
                    .peel_to_commit()
                    .map(|commit| commit.id().detach() != source_head)
                    .unwrap_or(true)
            })
    {
        return Ok(host_handoff_error(
            "destination-branch-exists",
            "Destination branch exists at a different commit",
        ));
    }

    copy_reachable_objects(&source, &destination, [source_head, source_snapshot])?;
    let nonce = format!("{}-{:x}", std::process::id(), timestamp_ms()?);
    let codex_home = params
        .get("codexHome")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".codex")))
        .ok_or(CoreError::InvalidArgument)?;
    let handoff_root = codex_home.join("handoffs").join(&nonce);
    fs::create_dir_all(&handoff_root).map_err(|_| CoreError::InvalidArgument)?;
    let rollout_path = handoff_root.join("rollout.jsonl");
    if fs::copy(source_rollout, &rollout_path).is_err() {
        let _ = fs::remove_dir_all(&handoff_root);
        return Ok(host_handoff_error(
            "bundle-import-failed",
            "Failed to copy source rollout",
        ));
    }

    let mut created_worktree = false;
    let resolved_root = if let Some(root) = destination_worktree_root {
        root.to_owned()
    } else {
        let repository_name = destination
            .workdir()
            .and_then(Path::file_name)
            .unwrap_or_else(|| std::ffi::OsStr::new("repository"));
        let root = codex_home
            .join("worktrees")
            .join(repository_name)
            .join(&nonce);
        retain_ref(
            &destination,
            &format!("refs/codex/handoff/{nonce}"),
            source_head,
        )?;
        let mut create = serde_json::Map::new();
        create.insert(
            "cwd".to_owned(),
            Value::String(destination_workspace.to_string_lossy().into_owned()),
        );
        create.insert(
            "worktreeRoot".to_owned(),
            Value::String(root.to_string_lossy().into_owned()),
        );
        create.insert(
            "startingState".to_owned(),
            json!({
                "type": "branch",
                "remoteRef": format!("refs/codex/handoff/{nonce}"),
            }),
        );
        if create_worktree(&create).is_err() {
            delete_ref(&destination, &format!("refs/codex/handoff/{nonce}"));
            let _ = fs::remove_dir_all(&handoff_root);
            return Ok(host_handoff_error(
                "create-worktree-failed",
                "Failed to create destination worktree",
            ));
        }
        delete_ref(&destination, &format!("refs/codex/handoff/{nonce}"));
        created_worktree = true;
        root
    };

    let target = match discover(&resolved_root) {
        Ok(repository) => repository,
        Err(_) => {
            let _ = fs::remove_dir_all(&handoff_root);
            return Ok(host_handoff_error(
                "create-worktree-failed",
                "Failed to resolve destination worktree",
            ));
        }
    };
    let target_head = target
        .head_id()
        .map_err(|_| CoreError::InvalidArgument)?
        .detach();
    let target_head_tree = target
        .find_commit(target_head)
        .map_err(|_| CoreError::InvalidArgument)?
        .tree_id()
        .map_err(|_| CoreError::InvalidArgument)?
        .detach();
    let target_snapshot = working_tree(&target, false)?;
    let target_diff = tree_patch(&resolved_root, target_head_tree, target_snapshot)?;
    if current_branch_name(&destination)?.as_deref() == Some(source_branch) {
        let destination_head = destination
            .head_id()
            .map_err(|_| CoreError::InvalidArgument)?
            .detach();
        set_checkout(
            &destination,
            None,
            destination_head,
            working_tree(&destination, false).ok(),
        )?;
    }
    retain_ref(
        &destination,
        &format!("refs/heads/{source_branch}"),
        source_head,
    )?;
    if set_checkout(
        &target,
        Some(source_branch),
        source_head,
        Some(target_snapshot),
    )
    .and_then(|_| restore_tree_to_worktree(&target, source_snapshot, Some(source_head_tree)))
    .and_then(|_| reset_index_to_tree(&target, source_head_tree))
    .is_err()
    {
        let _ = fs::remove_dir_all(&handoff_root);
        return Ok(host_handoff_error(
            "restore-worktree-state-failed",
            "Failed to restore transferred git state in the worktree",
        ));
    }
    if !target_diff.is_empty() && !apply_unstaged_patch(&resolved_root, target_diff)? {
        return Ok(host_handoff_error(
            "restore-worktree-state-failed",
            "Failed to restore destination worktree changes",
        ));
    }
    Ok(json!({
        "status": "success",
        "rolloutPath": rollout_path,
        "worktreeGitRoot": resolved_root,
        "worktreeWorkspaceRoot": resolved_root,
        "_progress": [
            {"step": "prepare-host-transfer", "status": "completed"},
            {"step": "transfer-host-artifacts", "status": "completed"},
            {"step": "create-new-worktree", "status": if created_worktree { "completed" } else { "skipped" }},
            {"step": "apply-changes-to-worktree", "status": "completed"},
        ],
    }))
}

fn cleanup_host_handoff_transfer(
    params: &serde_json::Map<String, Value>,
) -> Result<Value, CoreError> {
    let rollout_path = required_path(params, "rolloutPath")?;
    let codex_home = params
        .get("codexHome")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".codex")))
        .ok_or(CoreError::InvalidArgument)?;
    let handoffs = codex_home.join("handoffs");
    let parent = rollout_path.parent().ok_or(CoreError::InvalidArgument)?;
    let relative = parent
        .strip_prefix(&handoffs)
        .map_err(|_| CoreError::InvalidArgument)?;
    if rollout_path.file_name() != Some(std::ffi::OsStr::new("rollout.jsonl"))
        || relative.components().count() != 1
    {
        return Err(CoreError::InvalidArgument);
    }
    if parent.exists() {
        fs::remove_dir_all(parent).map_err(|_| CoreError::InvalidArgument)?;
    }
    Ok(json!({"success": true}))
}

fn commit_staged(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let include_unstaged = params
        .get("includeUnstaged")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let repository = discover(required_path(params, "cwd")?)?;
    let message = required_string(params, "message")?;
    let tree = if include_unstaged {
        stage_worktree(&repository)?
    } else {
        staged_tree(&repository)?
    };
    let parent = repository.head_id().ok().map(|id| id.detach());
    if let Some(parent) = parent {
        let head_tree = repository
            .find_commit(parent)
            .map_err(|_| CoreError::InvalidArgument)?
            .tree_id()
            .map_err(|_| CoreError::InvalidArgument)?
            .detach();
        if head_tree == tree {
            return Ok(json!({
                "status": "error",
                "error": "nothing to commit",
                "errorType": "nothing-to-commit",
                "execOutput": {
                    "exitCode": 1,
                    "stdout": "",
                    "stderr": "nothing to commit",
                    "command": "embedded git commit",
                },
            }));
        }
    }
    let parents = parent.into_iter().collect::<Vec<_>>();
    match repository.commit("HEAD", message, tree, parents) {
        Ok(id) => Ok(json!({
            "status": "success",
            "commitSha": id.to_string(),
        })),
        Err(error) => {
            let error = error.to_string();
            Ok(json!({
                "status": "error",
                "error": error,
                "execOutput": {
                    "exitCode": 1,
                    "stdout": "",
                    "stderr": error,
                    "command": "embedded git commit",
                },
            }))
        }
    }
}

#[derive(Clone, Debug)]
struct PatchLine {
    kind: u8,
    text: Vec<u8>,
}

#[derive(Clone, Debug)]
struct PatchHunk {
    old_start: usize,
    old_count: usize,
    new_start: usize,
    new_count: usize,
    lines: Vec<PatchLine>,
}

#[derive(Clone, Debug)]
struct FilePatch {
    old_path: Option<String>,
    new_path: Option<String>,
    hunks: Vec<PatchHunk>,
    binary: Option<(Vec<u8>, Vec<u8>)>,
}

fn patch_path(header: &[u8], prefix: &[u8]) -> Result<Option<String>, CoreError> {
    let value = header
        .strip_prefix(prefix)
        .ok_or(CoreError::InvalidArgument)?;
    let value = value.split(|byte| *byte == b'\t').next().unwrap_or(value);
    if value == b"/dev/null" {
        return Ok(None);
    }
    if value.first() == Some(&b'"') {
        return Err(CoreError::InvalidArgument);
    }
    let value = value
        .strip_prefix(b"a/")
        .or_else(|| value.strip_prefix(b"b/"))
        .unwrap_or(value);
    let value = std::str::from_utf8(value).map_err(|_| CoreError::InvalidArgument)?;
    if !safe_relative_path(value) || value.is_empty() {
        return Err(CoreError::InvalidArgument);
    }
    Ok(Some(value.to_owned()))
}

fn parse_range(value: &[u8], prefix: u8) -> Result<(usize, usize), CoreError> {
    let value = value
        .strip_prefix(&[prefix])
        .ok_or(CoreError::InvalidArgument)?;
    let value = std::str::from_utf8(value).map_err(|_| CoreError::InvalidArgument)?;
    let mut parts = value.split(',');
    let start = parts
        .next()
        .ok_or(CoreError::InvalidArgument)?
        .parse::<usize>()
        .map_err(|_| CoreError::InvalidArgument)?;
    let count = parts
        .next()
        .map(str::parse::<usize>)
        .transpose()
        .map_err(|_| CoreError::InvalidArgument)?
        .unwrap_or(1);
    if parts.next().is_some() {
        return Err(CoreError::InvalidArgument);
    }
    Ok((start, count))
}

fn parse_hunk_header(line: &[u8]) -> Result<(usize, usize, usize, usize), CoreError> {
    let line = line
        .strip_prefix(b"@@ ")
        .ok_or(CoreError::InvalidArgument)?;
    let end = line
        .windows(3)
        .position(|window| window == b" @@")
        .ok_or(CoreError::InvalidArgument)?;
    let ranges = &line[..end];
    let mut parts = ranges.split(|byte| *byte == b' ');
    let old = parse_range(parts.next().ok_or(CoreError::InvalidArgument)?, b'-')?;
    let new = parse_range(parts.next().ok_or(CoreError::InvalidArgument)?, b'+')?;
    if parts.next().is_some() {
        return Err(CoreError::InvalidArgument);
    }
    Ok((old.0, old.1, new.0, new.1))
}

fn patch_lines(input: &[u8]) -> Vec<Vec<u8>> {
    let mut lines = input
        .split_inclusive(|byte| *byte == b'\n')
        .map(<[u8]>::to_vec)
        .collect::<Vec<_>>();
    if input.is_empty() {
        lines.clear();
    }
    lines
}

const GIT_BASE85: &[u8; 85] =
    b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!#$%&()*+-;<=>?@^_`{|}~";

fn binary_header_paths(line: &[u8]) -> Result<(String, String), CoreError> {
    let line = line
        .strip_suffix(b"\n")
        .unwrap_or(line)
        .strip_prefix(b"diff --git a/")
        .ok_or(CoreError::InvalidArgument)?;
    let split = line
        .windows(3)
        .rposition(|window| window == b" b/")
        .ok_or(CoreError::InvalidArgument)?;
    let old = std::str::from_utf8(&line[..split]).map_err(|_| CoreError::InvalidArgument)?;
    let new = std::str::from_utf8(&line[split + 3..]).map_err(|_| CoreError::InvalidArgument)?;
    if !safe_relative_path(old) || !safe_relative_path(new) || old.is_empty() || new.is_empty() {
        return Err(CoreError::InvalidArgument);
    }
    Ok((old.to_owned(), new.to_owned()))
}

fn decode_binary_literal(lines: &[Vec<u8>], index: &mut usize) -> Result<Vec<u8>, CoreError> {
    let header = lines
        .get(*index)
        .ok_or(CoreError::InvalidArgument)?
        .strip_suffix(b"\n")
        .unwrap_or(&lines[*index]);
    let expected = std::str::from_utf8(
        header
            .strip_prefix(b"literal ")
            .ok_or(CoreError::UnsupportedCommand)?,
    )
    .map_err(|_| CoreError::InvalidArgument)?
    .parse::<usize>()
    .map_err(|_| CoreError::InvalidArgument)?;
    *index += 1;
    let mut compressed = Vec::new();
    while let Some(line) = lines.get(*index) {
        let line = line.strip_suffix(b"\n").unwrap_or(line);
        if line.is_empty() {
            *index += 1;
            break;
        }
        let encoded_len = match line[0] {
            b'A'..=b'Z' => (line[0] - b'A' + 1) as usize,
            b'a'..=b'z' => (line[0] - b'a' + 27) as usize,
            _ => break,
        };
        let encoded = &line[1..];
        if encoded.len() % 5 != 0 || encoded.len() / 5 * 4 < encoded_len {
            return Err(CoreError::InvalidArgument);
        }
        let mut decoded = Vec::with_capacity(encoded.len() / 5 * 4);
        for group in encoded.chunks(5) {
            let mut value = 0u32;
            for byte in group {
                let digit = GIT_BASE85
                    .iter()
                    .position(|candidate| candidate == byte)
                    .ok_or(CoreError::InvalidArgument)? as u32;
                value = value
                    .checked_mul(85)
                    .and_then(|value| value.checked_add(digit))
                    .ok_or(CoreError::InvalidArgument)?;
            }
            decoded.extend_from_slice(&value.to_be_bytes());
        }
        compressed.extend_from_slice(&decoded[..encoded_len]);
        *index += 1;
    }
    let mut decoder = ZlibDecoder::new(compressed.as_slice());
    let mut output = Vec::new();
    decoder
        .read_to_end(&mut output)
        .map_err(|_| CoreError::InvalidArgument)?;
    if output.len() != expected {
        return Err(CoreError::InvalidArgument);
    }
    Ok(output)
}

fn parse_binary_patches(lines: &[Vec<u8>]) -> Result<Vec<FilePatch>, CoreError> {
    let mut files = Vec::new();
    let mut block_start = 0usize;
    while block_start < lines.len() {
        if !lines[block_start].starts_with(b"diff --git ") {
            block_start += 1;
            continue;
        }
        let block_end = (block_start + 1..lines.len())
            .find(|index| lines[*index].starts_with(b"diff --git "))
            .unwrap_or(lines.len());
        let Some(binary_line) = (block_start + 1..block_end)
            .find(|index| lines[*index].starts_with(b"GIT binary patch"))
        else {
            block_start = block_end;
            continue;
        };
        let (header_old, header_new) = binary_header_paths(&lines[block_start])?;
        let new_file = lines[block_start + 1..binary_line]
            .iter()
            .any(|line| line.starts_with(b"new file mode "));
        let deleted_file = lines[block_start + 1..binary_line]
            .iter()
            .any(|line| line.starts_with(b"deleted file mode "));
        let mut index = binary_line + 1;
        let new_data = decode_binary_literal(lines, &mut index)?;
        let old_data = decode_binary_literal(lines, &mut index)?;
        files.push(FilePatch {
            old_path: (!new_file).then_some(header_old),
            new_path: (!deleted_file).then_some(header_new),
            hunks: Vec::new(),
            binary: Some((new_data, old_data)),
        });
        block_start = block_end;
    }
    Ok(files)
}

fn parse_rename_patches(lines: &[Vec<u8>]) -> Result<Vec<FilePatch>, CoreError> {
    let mut files = Vec::new();
    let mut block_start = 0usize;
    while block_start < lines.len() {
        if !lines[block_start].starts_with(b"diff --git ") {
            block_start += 1;
            continue;
        }
        let block_end = (block_start + 1..lines.len())
            .find(|index| lines[*index].starts_with(b"diff --git "))
            .unwrap_or(lines.len());
        let rename_from =
            (block_start + 1..block_end).find(|index| lines[*index].starts_with(b"rename from "));
        let rename_to =
            (block_start + 1..block_end).find(|index| lines[*index].starts_with(b"rename to "));
        match (rename_from, rename_to) {
            (None, None) => {}
            (Some(from), Some(to)) => {
                if (block_start + 1..block_end).any(|index| {
                    lines[index].starts_with(b"GIT binary patch")
                        || lines[index].starts_with(b"--- ")
                }) {
                    return Err(CoreError::UnsupportedCommand);
                }
                let old_path = patch_path(
                    lines[from].strip_suffix(b"\n").unwrap_or(&lines[from]),
                    b"rename from ",
                )?
                .ok_or(CoreError::InvalidArgument)?;
                let new_path = patch_path(
                    lines[to].strip_suffix(b"\n").unwrap_or(&lines[to]),
                    b"rename to ",
                )?
                .ok_or(CoreError::InvalidArgument)?;
                files.push(FilePatch {
                    old_path: Some(old_path),
                    new_path: Some(new_path),
                    hunks: Vec::new(),
                    binary: None,
                });
            }
            _ => return Err(CoreError::InvalidArgument),
        }
        block_start = block_end;
    }
    Ok(files)
}

fn parse_patch(input: &[u8]) -> Result<Vec<FilePatch>, CoreError> {
    if input
        .windows(b"Binary files ".len())
        .any(|window| window == b"Binary files ")
    {
        return Err(CoreError::UnsupportedCommand);
    }
    let lines = patch_lines(input);
    let mut files = parse_binary_patches(&lines)?;
    files.extend(parse_rename_patches(&lines)?);
    let mut index = 0;
    while index < lines.len() {
        if !lines[index].starts_with(b"--- ") {
            index += 1;
            continue;
        }
        let old_path = patch_path(
            lines[index].strip_suffix(b"\n").unwrap_or(&lines[index]),
            b"--- ",
        )?;
        index += 1;
        if index >= lines.len() || !lines[index].starts_with(b"+++ ") {
            return Err(CoreError::InvalidArgument);
        }
        let new_path = patch_path(
            lines[index].strip_suffix(b"\n").unwrap_or(&lines[index]),
            b"+++ ",
        )?;
        index += 1;
        let mut hunks = Vec::new();
        while index < lines.len() {
            if lines[index].starts_with(b"--- ") {
                break;
            }
            if !lines[index].starts_with(b"@@ ") {
                index += 1;
                continue;
            }
            let header = lines[index].strip_suffix(b"\n").unwrap_or(&lines[index]);
            let (old_start, old_count, new_start, new_count) = parse_hunk_header(header)?;
            index += 1;
            let mut hunk_lines = Vec::<PatchLine>::new();
            while index < lines.len() {
                let line = &lines[index];
                if line.starts_with(b"@@ ") || line.starts_with(b"--- ") {
                    break;
                }
                if line.starts_with(b"\\ No newline at end of file") {
                    let previous = hunk_lines.last_mut().ok_or(CoreError::InvalidArgument)?;
                    if previous.text.last() == Some(&b'\n') {
                        previous.text.pop();
                    }
                    index += 1;
                    continue;
                }
                let kind = *line.first().ok_or(CoreError::InvalidArgument)?;
                if !matches!(kind, b' ' | b'+' | b'-') {
                    break;
                }
                hunk_lines.push(PatchLine {
                    kind,
                    text: line[1..].to_vec(),
                });
                index += 1;
            }
            let actual_old = hunk_lines.iter().filter(|line| line.kind != b'+').count();
            let actual_new = hunk_lines.iter().filter(|line| line.kind != b'-').count();
            if actual_old != old_count || actual_new != new_count {
                return Err(CoreError::InvalidArgument);
            }
            hunks.push(PatchHunk {
                old_start,
                old_count,
                new_start,
                new_count,
                lines: hunk_lines,
            });
        }
        if old_path.is_none() && new_path.is_none() || hunks.is_empty() {
            return Err(CoreError::InvalidArgument);
        }
        files.push(FilePatch {
            old_path,
            new_path,
            hunks,
            binary: None,
        });
    }
    if files.is_empty() {
        return Err(CoreError::InvalidArgument);
    }
    Ok(files)
}

fn reversed_patch(patch: &FilePatch) -> FilePatch {
    FilePatch {
        old_path: patch.new_path.clone(),
        new_path: patch.old_path.clone(),
        hunks: patch
            .hunks
            .iter()
            .map(|hunk| PatchHunk {
                old_start: hunk.new_start,
                old_count: hunk.new_count,
                new_start: hunk.old_start,
                new_count: hunk.old_count,
                lines: hunk
                    .lines
                    .iter()
                    .map(|line| PatchLine {
                        kind: match line.kind {
                            b'+' => b'-',
                            b'-' => b'+',
                            kind => kind,
                        },
                        text: line.text.clone(),
                    })
                    .collect(),
            })
            .collect(),
        binary: patch
            .binary
            .as_ref()
            .map(|(new, old)| (old.clone(), new.clone())),
    }
}

fn apply_patch_to_original(
    patch: &FilePatch,
    original: Option<&[u8]>,
) -> Result<(String, Option<Vec<u8>>), ()> {
    let old = patch.old_path.as_deref();
    let new = patch.new_path.as_deref();
    let result_path = new.or(old).ok_or(())?.to_owned();
    if let Some((new_data, old_data)) = &patch.binary {
        match (old, original) {
            (Some(_), Some(original)) if original == old_data => {}
            (None, None) if old_data.is_empty() => {}
            _ => return Err(()),
        }
        return Ok((result_path, new.map(|_| new_data.clone())));
    }
    let original = match (old, original) {
        (Some(_), Some(original)) => original,
        (None, None) => &[],
        _ => return Err(()),
    };
    if patch.hunks.is_empty() {
        return match (old, new) {
            (Some(_), Some(_)) => Ok((result_path, Some(original.to_vec()))),
            _ => Err(()),
        };
    }
    let original_lines = patch_lines(original);
    let mut output = Vec::new();
    let mut cursor = 0usize;
    for hunk in &patch.hunks {
        let start = if hunk.old_start == 0 {
            0
        } else {
            hunk.old_start - 1
        };
        if start < cursor || start > original_lines.len() {
            return Err(());
        }
        for line in &original_lines[cursor..start] {
            output.extend_from_slice(line);
        }
        cursor = start;
        for line in &hunk.lines {
            match line.kind {
                b' ' => {
                    if original_lines.get(cursor).map(Vec::as_slice) != Some(line.text.as_slice()) {
                        return Err(());
                    }
                    output.extend_from_slice(&line.text);
                    cursor += 1;
                }
                b'-' => {
                    if original_lines.get(cursor).map(Vec::as_slice) != Some(line.text.as_slice()) {
                        return Err(());
                    }
                    cursor += 1;
                }
                b'+' => output.extend_from_slice(&line.text),
                _ => return Err(()),
            }
        }
    }
    for line in &original_lines[cursor..] {
        output.extend_from_slice(line);
    }
    Ok((result_path, new.map(|_| output)))
}

fn apply_file_patch(root: &Path, patch: &FilePatch) -> Result<(String, Option<Vec<u8>>), ()> {
    if let (Some(old), Some(new)) = (patch.old_path.as_deref(), patch.new_path.as_deref())
        && old != new
        && root.join(new).exists()
    {
        return Err(());
    }
    let original = match patch.old_path.as_deref() {
        Some(path) => Some(fs::read(root.join(path)).map_err(|_| ())?),
        None => {
            if patch
                .new_path
                .as_deref()
                .is_some_and(|path| root.join(path).exists())
            {
                return Err(());
            }
            None
        }
    };
    apply_patch_to_original(patch, original.as_deref())
}

#[derive(Clone)]
struct PreparedWorktreePatch {
    old_path: Option<String>,
    path: String,
    contents: Option<Vec<u8>>,
}

#[derive(Clone)]
struct PreparedIndexPatch {
    old_path: Option<String>,
    path: String,
    contents: Option<Vec<u8>>,
    kind: gix::object::tree::EntryKind,
}

fn prepare_index_patch(
    repository: &gix::Repository,
    index: &gix::index::File,
    patch: &FilePatch,
) -> Result<PreparedIndexPatch, ()> {
    let old_entry = patch.old_path.as_deref().and_then(|path| {
        index
            .entries()
            .iter()
            .find(|entry| entry.path(index).as_bytes() == path.as_bytes())
    });
    if patch.old_path.is_some() != old_entry.is_some() {
        return Err(());
    }
    if patch.old_path.is_none()
        && patch.new_path.as_deref().is_some_and(|path| {
            index
                .entries()
                .iter()
                .any(|entry| entry.path(index).as_bytes() == path.as_bytes())
        })
    {
        return Err(());
    }
    if let (Some(old), Some(new)) = (patch.old_path.as_deref(), patch.new_path.as_deref())
        && old != new
        && index
            .entries()
            .iter()
            .any(|entry| entry.path(index).as_bytes() == new.as_bytes())
    {
        return Err(());
    }
    let (kind, original) = match old_entry {
        Some(entry) => {
            if entry.stage() != gix::index::entry::Stage::Unconflicted || entry.mode.is_sparse() {
                return Err(());
            }
            let kind = entry.mode.to_tree_entry_mode().ok_or(())?.kind();
            if matches!(
                kind,
                gix::object::tree::EntryKind::Tree | gix::object::tree::EntryKind::Commit
            ) {
                return Err(());
            }
            let blob = repository.find_blob(entry.id).map_err(|_| ())?;
            (kind, Some(blob.data.clone()))
        }
        None => (gix::object::tree::EntryKind::Blob, None),
    };
    let (path, contents) = apply_patch_to_original(patch, original.as_deref())?;
    Ok(PreparedIndexPatch {
        old_path: patch.old_path.clone(),
        path,
        contents,
        kind,
    })
}

fn persist_index_patches(
    repository: &gix::Repository,
    index: &gix::index::File,
    prepared: &[PreparedIndexPatch],
) -> Result<(), CoreError> {
    let mut editor = repository
        .empty_tree()
        .edit()
        .map_err(|_| CoreError::InvalidArgument)?;
    for entry in index.entries() {
        if entry.stage() != gix::index::entry::Stage::Unconflicted || entry.mode.is_sparse() {
            return Err(CoreError::InvalidArgument);
        }
        let mode = entry
            .mode
            .to_tree_entry_mode()
            .ok_or(CoreError::InvalidArgument)?;
        editor
            .upsert(entry.path(index).to_owned(), mode.kind(), entry.id)
            .map_err(|_| CoreError::InvalidArgument)?;
    }
    for patch in prepared {
        if patch
            .old_path
            .as_deref()
            .is_some_and(|old| old != patch.path)
        {
            editor
                .remove(patch.old_path.as_deref().unwrap())
                .map_err(|_| CoreError::InvalidArgument)?;
        }
        match &patch.contents {
            Some(contents) => {
                let id = repository
                    .write_blob(contents)
                    .map_err(|_| CoreError::InvalidArgument)?
                    .detach();
                editor
                    .upsert(&patch.path, patch.kind, id)
                    .map_err(|_| CoreError::InvalidArgument)?;
            }
            None => {
                editor
                    .remove(&patch.path)
                    .map_err(|_| CoreError::InvalidArgument)?;
            }
        }
    }
    let tree = editor
        .write()
        .map_err(|_| CoreError::InvalidArgument)?
        .detach();
    let mut updated = repository
        .index_from_tree(&tree)
        .map_err(|_| CoreError::InvalidArgument)?;
    updated
        .write(gix::index::write::Options::default())
        .map_err(|_| CoreError::InvalidArgument)
}

fn patch_exec_output(success: bool, message: &str) -> Value {
    json!({
        "exitCode": if success { 0 } else { 1 },
        "stdout": if success { "Patch applied" } else { "" },
        "stderr": if success { "" } else { message },
        "command": "embedded git apply",
    })
}

fn apply_patch(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let root = required_path(params, "cwd")?;
    let repository = discover(root)?;
    let diff = required_string(params, "diff")?;
    let atomic = params
        .get("atomic")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let revert = params
        .get("revert")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let target = params
        .get("target")
        .and_then(Value::as_str)
        .unwrap_or("unstaged");
    if !matches!(target, "unstaged" | "staged" | "staged-and-unstaged") {
        return Err(CoreError::InvalidArgument);
    }
    let parsed = parse_patch(diff.as_bytes())?;
    let parsed = if revert {
        parsed.iter().map(reversed_patch).collect::<Vec<_>>()
    } else {
        parsed
    };
    let index = if target == "unstaged" {
        None
    } else {
        Some(
            repository
                .index_or_load_from_head_or_empty()
                .map_err(|_| CoreError::InvalidArgument)?,
        )
    };
    let mut prepared = Vec::new();
    let mut prepared_index = Vec::new();
    let mut conflicted = Vec::new();
    for patch in &parsed {
        let worktree_result = if target == "staged" {
            None
        } else {
            Some(apply_file_patch(root, patch))
        };
        let index_result = index
            .as_ref()
            .map(|index| prepare_index_patch(&repository, index, patch));
        let worktree_matches_index = if target == "staged-and-unstaged" {
            match patch.old_path.as_deref() {
                Some(path) => {
                    let worktree = fs::read(root.join(path)).ok();
                    let staged = index.as_ref().and_then(|index| {
                        index
                            .entries()
                            .iter()
                            .find(|entry| entry.path(index).as_bytes() == path.as_bytes())
                            .and_then(|entry| repository.find_blob(entry.id).ok())
                            .map(|blob| blob.data.clone())
                    });
                    worktree == staged
                }
                None => true,
            }
        } else {
            true
        };
        let succeeded = worktree_result.as_ref().is_none_or(Result::is_ok)
            && index_result.as_ref().is_none_or(Result::is_ok)
            && worktree_matches_index;
        if succeeded {
            if let Some(Ok(result)) = worktree_result {
                prepared.push(PreparedWorktreePatch {
                    old_path: patch.old_path.clone(),
                    path: result.0,
                    contents: result.1,
                });
            }
            if let Some(Ok(result)) = index_result {
                prepared_index.push(result);
            }
        } else {
            let path = patch
                .new_path
                .as_ref()
                .or(patch.old_path.as_ref())
                .cloned()
                .unwrap_or_default();
            conflicted.push(path);
            if atomic {
                return Ok(json!({
                    "status": "error",
                    "appliedPaths": [],
                    "skippedPaths": [],
                    "conflictedPaths": conflicted,
                    "execOutput": patch_exec_output(false, "Patch context did not match"),
                }));
            }
        }
    }
    let backups = if atomic {
        prepared
            .iter()
            .flat_map(|patch| patch.old_path.iter().chain(std::iter::once(&patch.path)))
            .collect::<BTreeSet<_>>()
            .into_iter()
            .map(|path| {
                let destination = root.join(path);
                let previous = match fs::read(&destination) {
                    Ok(contents) => Some(contents),
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
                    Err(_) => return Err(CoreError::InvalidArgument),
                };
                Ok((path.clone(), previous))
            })
            .collect::<Result<Vec<_>, CoreError>>()?
    } else {
        Vec::new()
    };
    let mut applied = Vec::new();
    for patch in prepared {
        let destination = root.join(&patch.path);
        let old_path = patch.old_path.as_deref();
        let is_rename = old_path.is_some_and(|old| old != patch.path);
        let result = match patch.contents {
            Some(contents) => {
                let write = atomic_write(&destination, &contents);
                if write.is_err() {
                    write
                } else if is_rename {
                    let old_destination = root.join(old_path.unwrap());
                    if fs::remove_file(&old_destination).is_err() {
                        let _ = fs::remove_file(&destination);
                        Err(CoreError::InvalidArgument)
                    } else {
                        Ok(())
                    }
                } else {
                    Ok(())
                }
            }
            None => fs::remove_file(&destination).map_err(|_| CoreError::InvalidArgument),
        };
        if result.is_ok() {
            applied.push(patch.path);
        } else {
            conflicted.push(patch.path);
            if atomic {
                for (restore_path, previous) in backups.iter().rev() {
                    let destination = root.join(restore_path);
                    match previous {
                        Some(contents) => {
                            let _ = atomic_write(&destination, contents);
                        }
                        None => {
                            let _ = fs::remove_file(destination);
                        }
                    }
                }
                return Ok(json!({
                    "status": "error",
                    "appliedPaths": [],
                    "skippedPaths": [],
                    "conflictedPaths": conflicted,
                    "execOutput": patch_exec_output(false, "Patch write failed and was rolled back"),
                }));
            }
        }
    }
    if target == "staged-and-unstaged" && !atomic {
        prepared_index.retain(|patch| applied.contains(&patch.path));
    }
    if !prepared_index.is_empty() {
        if persist_index_patches(
            &repository,
            index.as_ref().ok_or(CoreError::InvalidArgument)?,
            &prepared_index,
        )
        .is_err()
        {
            if atomic {
                for (restore_path, previous) in backups.iter().rev() {
                    let destination = root.join(restore_path);
                    match previous {
                        Some(contents) => {
                            let _ = atomic_write(&destination, contents);
                        }
                        None => {
                            let _ = fs::remove_file(destination);
                        }
                    }
                }
                applied.clear();
            }
            for patch in &prepared_index {
                if !conflicted.contains(&patch.path) {
                    conflicted.push(patch.path.clone());
                }
            }
        } else if target == "staged" {
            applied.extend(prepared_index.iter().map(|patch| patch.path.clone()));
        }
    }
    let success = conflicted.is_empty();
    Ok(json!({
        "status": if success { "success" } else if applied.is_empty() { "error" } else { "partial-success" },
        "appliedPaths": applied,
        "skippedPaths": [],
        "conflictedPaths": conflicted,
        "execOutput": patch_exec_output(success, if success { "Patch applied" } else { "Patch partially applied" }),
    }))
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct TextEdit {
    start: usize,
    end: usize,
    replacement: Vec<u8>,
}

fn text_edits(base: &[u8], changed: &[u8]) -> Result<Vec<TextEdit>, ()> {
    let hunks = git_diff::text_hunks(base, changed).map_err(|_| ())?;
    if hunks.is_empty() {
        return Ok(Vec::new());
    }
    let mut patch = b"--- a/merge\n+++ b/merge\n".to_vec();
    patch.extend_from_slice(&hunks);
    let parsed = parse_patch(&patch).map_err(|_| ())?;
    let mut edits = Vec::new();
    for hunk in &parsed.first().ok_or(())?.hunks {
        let mut base_position = hunk.old_start.saturating_sub(1);
        let mut pending: Option<TextEdit> = None;
        let flush = |pending: &mut Option<TextEdit>, edits: &mut Vec<TextEdit>| {
            if let Some(edit) = pending.take() {
                edits.push(edit);
            }
        };
        for line in &hunk.lines {
            match line.kind {
                b' ' => {
                    flush(&mut pending, &mut edits);
                    base_position += 1;
                }
                b'-' => {
                    let edit = pending.get_or_insert_with(|| TextEdit {
                        start: base_position,
                        end: base_position,
                        replacement: Vec::new(),
                    });
                    edit.end += 1;
                    base_position += 1;
                }
                b'+' => {
                    pending
                        .get_or_insert_with(|| TextEdit {
                            start: base_position,
                            end: base_position,
                            replacement: Vec::new(),
                        })
                        .replacement
                        .extend_from_slice(&line.text);
                }
                _ => return Err(()),
            }
        }
        flush(&mut pending, &mut edits);
    }
    Ok(edits)
}

fn edits_overlap(left: &TextEdit, right: &TextEdit) -> bool {
    if left.start == left.end && right.start == right.end {
        return left.start == right.start;
    }
    if left.start == left.end {
        return left.start >= right.start && left.start < right.end;
    }
    if right.start == right.end {
        return right.start >= left.start && right.start < left.end;
    }
    left.start < right.end && right.start < left.end
}

fn three_way_text_merge(base: &[u8], ours: &[u8], theirs: &[u8]) -> Option<Vec<u8>> {
    let mut edits = text_edits(base, ours)
        .ok()?
        .into_iter()
        .map(|edit| (edit, 0u8))
        .chain(
            text_edits(base, theirs)
                .ok()?
                .into_iter()
                .map(|edit| (edit, 1u8)),
        )
        .collect::<Vec<_>>();
    edits.sort_by(|left, right| {
        left.0
            .start
            .cmp(&right.0.start)
            .then(left.0.end.cmp(&right.0.end))
            .then(left.1.cmp(&right.1))
    });
    let mut merged = Vec::<TextEdit>::new();
    for (edit, _) in edits {
        if let Some(previous) = merged.last() {
            if *previous == edit {
                continue;
            }
            if edits_overlap(previous, &edit) {
                return None;
            }
        }
        merged.push(edit);
    }
    let base_lines = patch_lines(base);
    let mut output = Vec::new();
    let mut cursor = 0usize;
    for edit in merged {
        if edit.start < cursor || edit.end > base_lines.len() {
            return None;
        }
        for line in &base_lines[cursor..edit.start] {
            output.extend_from_slice(line);
        }
        output.extend_from_slice(&edit.replacement);
        cursor = edit.end;
    }
    for line in &base_lines[cursor..] {
        output.extend_from_slice(line);
    }
    Some(output)
}

fn apply_changes(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let source_head_ref = required_string(params, "sourceHeadRef")?;
    let source_tree_ref = required_string(params, "sourceTreeRef")?;
    let destination_root = required_path(params, "destinationRoot")?;
    let destination_head_ref = required_string(params, "destinationHeadRef")?;
    let diff = match git_diff::merge_base_diff(
        destination_root,
        source_head_ref,
        source_tree_ref,
        destination_head_ref,
    ) {
        Ok(diff) => diff,
        Err(error) => {
            let error = error.to_string();
            return Ok(json!({
                "status": "command-error",
                "execOutput": {
                    "exitCode": 1,
                    "stdout": "",
                    "stderr": error,
                    "command": "embedded git merge-base/diff",
                },
            }));
        }
    };
    if diff.is_empty() {
        return Ok(json!({"status": "success"}));
    }
    let merge_material = match git_diff::merge_base_material(
        destination_root,
        source_head_ref,
        source_tree_ref,
        destination_head_ref,
    ) {
        Ok(material) => material,
        Err(error) => {
            let error = error.to_string();
            return Ok(json!({
                "status": "command-error",
                "execOutput": {
                    "exitCode": 1,
                    "stdout": "",
                    "stderr": error,
                    "command": "embedded git merge-base/material",
                },
            }));
        }
    };
    let mut patch_params = serde_json::Map::new();
    patch_params.insert(
        "cwd".to_owned(),
        Value::String(destination_root.to_string_lossy().into_owned()),
    );
    patch_params.insert("diff".to_owned(), Value::String(diff));
    patch_params.insert("atomic".to_owned(), Value::Bool(false));
    patch_params.insert("target".to_owned(), Value::String("unstaged".to_owned()));
    let applied = apply_patch(&patch_params)?;
    if applied.get("status").and_then(Value::as_str) == Some("success") {
        return Ok(json!({"status": "success"}));
    }
    let mut applied_paths = applied["appliedPaths"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    let conflicted_paths = applied["conflictedPaths"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    if conflicted_paths.is_empty() {
        return Ok(json!({
            "status": "command-error",
            "execOutput": applied["execOutput"],
        }));
    }
    let mut unresolved = Vec::new();
    for value in conflicted_paths {
        let Some(path) = value.as_str() else {
            return Err(CoreError::InvalidArgument);
        };
        let Some(material) = merge_material.get(path) else {
            unresolved.push(value);
            continue;
        };
        let ours = match fs::read(destination_root.join(path)) {
            Ok(contents) => Some(contents),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
            Err(_) => return Err(CoreError::InvalidArgument),
        };
        if ours == material.theirs {
            applied_paths.push(Value::String(path.to_owned()));
            continue;
        }
        let is_text = [&material.base, &ours, &material.theirs]
            .into_iter()
            .flatten()
            .all(|contents| !contents.contains(&0) && std::str::from_utf8(contents).is_ok());
        if is_text
            && let (Some(base), Some(ours), Some(theirs)) =
                (&material.base, &ours, &material.theirs)
            && let Some(merged) = three_way_text_merge(base, ours, theirs)
        {
            atomic_write(&destination_root.join(path), &merged)?;
            applied_paths.push(Value::String(path.to_owned()));
            continue;
        }
        if is_text {
            let mut conflict = Vec::new();
            conflict.extend_from_slice(b"<<<<<<< destination\n");
            if let Some(contents) = &ours {
                conflict.extend_from_slice(contents);
                if !contents.ends_with(b"\n") {
                    conflict.push(b'\n');
                }
            }
            conflict.extend_from_slice(b"=======\n");
            if let Some(contents) = &material.theirs {
                conflict.extend_from_slice(contents);
                if !contents.ends_with(b"\n") {
                    conflict.push(b'\n');
                }
            }
            conflict.extend_from_slice(b">>>>>>> source\n");
            atomic_write(&destination_root.join(path), &conflict)?;
        }
        unresolved.push(Value::String(path.to_owned()));
    }
    if unresolved.is_empty() {
        Ok(json!({"status": "success"}))
    } else {
        Ok(json!({
            "status": "partial-success",
            "appliedPaths": applied_paths,
            "skippedPaths": [],
            "conflictedPaths": unresolved,
        }))
    }
}

fn apply_review_section_changes(
    params: &serde_json::Map<String, Value>,
) -> Result<Value, CoreError> {
    let action = required_string(params, "action")?;
    let cwd = required_path(params, "cwd")?;
    let source = required_string(params, "source")?;
    if !matches!(action, "stage" | "unstage" | "revert")
        || !matches!(source, "staged" | "unstaged" | "uncommitted")
    {
        return Err(CoreError::InvalidArgument);
    }
    let files = params
        .get("files")
        .and_then(Value::as_array)
        .ok_or(CoreError::InvalidArgument)?;
    let mut paths = Vec::new();
    let mut requested_revisions = std::collections::BTreeMap::new();
    for file in files {
        let file = file.as_object().ok_or(CoreError::InvalidArgument)?;
        let path = file
            .get("path")
            .and_then(Value::as_str)
            .filter(|path| safe_relative_path(path))
            .ok_or(CoreError::InvalidArgument)?;
        let revision = file
            .get("revision")
            .and_then(Value::as_str)
            .filter(|revision| !revision.is_empty())
            .ok_or(CoreError::InvalidArgument)?;
        if file
            .get("previousPath")
            .is_some_and(|value| !value.is_null())
        {
            return Err(CoreError::UnsupportedCommand);
        }
        if !paths.iter().any(|candidate| candidate == path) {
            paths.push(path.to_owned());
        }
        requested_revisions.insert(path.to_owned(), revision.to_owned());
    }
    let invalid_selection = |conflicted_paths: &[String]| {
        json!({
            "status": "error",
            "errorCode": "stale-or-invalid-selection",
            "appliedPaths": [],
            "skippedPaths": [],
            "conflictedPaths": conflicted_paths,
        })
    };
    if paths.is_empty() {
        return Ok(invalid_selection(&[]));
    }
    let summary = git_diff::review_summary(cwd, source, None, None, &paths, true)
        .map_err(|_| CoreError::InvalidArgument)?;
    let current_revisions = summary
        .get("files")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|file| {
            Some((
                file.get("path")?.as_str()?.to_owned(),
                file.get("revision")?.as_str()?.to_owned(),
            ))
        })
        .collect::<std::collections::BTreeMap<_, _>>();
    if requested_revisions
        .iter()
        .any(|(path, revision)| current_revisions.get(path) != Some(revision))
    {
        return Ok(invalid_selection(&paths));
    }
    let diff = match git_diff::review_action_patch(cwd, source, &paths) {
        Ok(diff) => diff,
        Err(_) => return Err(CoreError::InvalidArgument),
    };
    if diff.is_empty() {
        return Ok(invalid_selection(&paths));
    }
    let (target, revert) = match action {
        "stage" => ("staged", false),
        "unstage" => ("staged", true),
        "revert" if source == "staged" => ("staged-and-unstaged", true),
        "revert" => ("unstaged", true),
        _ => return Err(CoreError::InvalidArgument),
    };
    let mut patch_params = serde_json::Map::new();
    patch_params.insert(
        "cwd".to_owned(),
        Value::String(cwd.to_string_lossy().into_owned()),
    );
    patch_params.insert("diff".to_owned(), Value::String(diff));
    patch_params.insert("atomic".to_owned(), Value::Bool(true));
    patch_params.insert("revert".to_owned(), Value::Bool(revert));
    patch_params.insert("target".to_owned(), Value::String(target.to_owned()));
    apply_patch(&patch_params)
}

fn checkout_detached_worktree(
    repository: &gix::Repository,
    commit: gix::ObjectId,
    root: &Path,
    admin: &Path,
) -> Result<(), CoreError> {
    let tree = repository
        .find_commit(commit)
        .map_err(|_| CoreError::InvalidArgument)?
        .tree_id()
        .map_err(|_| CoreError::InvalidArgument)?
        .detach();
    let mut index = repository
        .index_from_tree(&tree)
        .map_err(|_| CoreError::InvalidArgument)?;
    for entry in index.entries() {
        if entry.mode.is_sparse() || entry.mode == gix::index::entry::Mode::COMMIT {
            return Err(CoreError::UnsupportedCommand);
        }
        let path = root.join(gix::path::from_bstr(entry.path(&index)).as_ref());
        let parent = path.parent().ok_or(CoreError::InvalidArgument)?;
        fs::create_dir_all(parent).map_err(|_| CoreError::InvalidArgument)?;
        let blob = repository
            .find_blob(entry.id)
            .map_err(|_| CoreError::InvalidArgument)?;
        if entry.mode == gix::index::entry::Mode::SYMLINK {
            std::os::unix::fs::symlink(std::ffi::OsStr::from_bytes(&blob.data), &path)
                .map_err(|_| CoreError::InvalidArgument)?;
        } else {
            fs::write(&path, &blob.data).map_err(|_| CoreError::InvalidArgument)?;
            if entry.mode == gix::index::entry::Mode::FILE_EXECUTABLE {
                fs::set_permissions(&path, fs::Permissions::from_mode(0o755))
                    .map_err(|_| CoreError::InvalidArgument)?;
            }
        }
    }
    index.set_path(admin.join("index"));
    index
        .write(gix::index::write::Options::default())
        .map_err(|_| CoreError::InvalidArgument)
}

fn create_worktree(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let cwd = required_path(params, "cwd")?;
    let root = required_path(params, "worktreeRoot")?;
    if root.exists() {
        return Err(CoreError::InvalidArgument);
    }
    let repository = discover(cwd)?;
    let starting_state = params.get("startingState").and_then(Value::as_object);
    let (starting_ref, copy_working_tree) = match starting_state
        .and_then(|state| state.get("type"))
        .and_then(Value::as_str)
    {
        Some("branch") => (
            starting_state
                .and_then(|state| {
                    state
                        .get("branchName")
                        .or_else(|| state.get("remoteRef"))
                        .and_then(Value::as_str)
                })
                .unwrap_or("HEAD"),
            false,
        ),
        Some("working-tree") => ("HEAD", true),
        None => ("HEAD", false),
        _ => return Err(CoreError::InvalidArgument),
    };
    let commit = repository
        .rev_parse_single(starting_ref)
        .map_err(|_| CoreError::InvalidArgument)?
        .object()
        .map_err(|_| CoreError::InvalidArgument)?
        .peel_to_kind(gix::object::Kind::Commit)
        .map_err(|_| CoreError::InvalidArgument)?
        .id;
    let leaf = root
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("worktree")
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || character == '-' {
                character
            } else {
                '-'
            }
        })
        .collect::<String>();
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| CoreError::InvalidArgument)?
        .as_nanos();
    let admin = repository
        .common_dir()
        .join("worktrees")
        .join(format!("{leaf}-{nonce:x}"));
    fs::create_dir_all(root).map_err(|_| CoreError::InvalidArgument)?;
    if let Err(error) = (|| {
        fs::create_dir_all(&admin).map_err(|_| CoreError::InvalidArgument)?;
        atomic_write(
            &root.join(".git"),
            format!("gitdir: {}\n", admin.display()).as_bytes(),
        )?;
        atomic_write(
            &admin.join("gitdir"),
            format!("{}\n", root.join(".git").display()).as_bytes(),
        )?;
        atomic_write(&admin.join("commondir"), b"../..\n")?;
        atomic_write(&admin.join("HEAD"), format!("{commit}\n").as_bytes())?;
        checkout_detached_worktree(&repository, commit, root, &admin)?;
        if copy_working_tree {
            let summary = git_diff::review_summary(cwd, "uncommitted", None, None, &[], true)
                .map_err(|_| CoreError::InvalidArgument)?;
            let paths = summary
                .get("files")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|file| file.get("path").and_then(Value::as_str).map(str::to_owned))
                .collect::<Vec<_>>();
            if !paths.is_empty() {
                let diff = git_diff::review_action_patch(cwd, "uncommitted", &paths)
                    .map_err(|_| CoreError::InvalidArgument)?;
                if !diff.is_empty() {
                    let mut patch_params = serde_json::Map::new();
                    patch_params.insert(
                        "cwd".to_owned(),
                        Value::String(root.to_string_lossy().into_owned()),
                    );
                    patch_params.insert("diff".to_owned(), Value::String(diff));
                    patch_params.insert("atomic".to_owned(), Value::Bool(true));
                    patch_params.insert("target".to_owned(), Value::String("unstaged".to_owned()));
                    if apply_patch(&patch_params)?["status"] != "success" {
                        return Err(CoreError::InvalidArgument);
                    }
                }
            }
        }
        Ok(())
    })() {
        let _ = fs::remove_dir_all(root);
        let _ = fs::remove_dir_all(admin);
        return Err(error);
    }
    Ok(json!({
        "worktreeGitRoot": root,
        "worktreeWorkspaceRoot": root,
        "setupError": null,
    }))
}

fn linked_worktree_admin(worktree: &Path) -> Result<std::path::PathBuf, CoreError> {
    let git_file =
        fs::read_to_string(worktree.join(".git")).map_err(|_| CoreError::InvalidArgument)?;
    let path = git_file
        .trim()
        .strip_prefix("gitdir: ")
        .ok_or(CoreError::InvalidArgument)?;
    let path = Path::new(path);
    Ok(if path.is_absolute() {
        path.to_owned()
    } else {
        worktree.join(path)
    })
}

fn delete_worktree(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let worktree = required_path(params, "worktree")?;
    let force = params
        .get("force")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    if !force {
        let counts =
            git_diff::status_counts(worktree, true).map_err(|_| CoreError::InvalidArgument)?;
        if counts.staged != 0 || counts.unstaged != 0 || counts.untracked != 0 {
            return Err(CoreError::InvalidArgument);
        }
    }
    let admin = linked_worktree_admin(worktree)?;
    fs::remove_dir_all(worktree).map_err(|_| CoreError::InvalidArgument)?;
    fs::remove_dir_all(admin).map_err(|_| CoreError::InvalidArgument)?;
    let id = format!("{:x}", Sha1::digest(worktree.as_os_str().as_bytes()));
    Ok(json!({"success": true, "worktreeId": id}))
}

fn restore_worktree(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let repo_root = required_path(params, "repoRoot")?;
    let worktree = required_path(params, "worktreePath")?;
    let repository = discover(repo_root)?;
    let admin = linked_worktree_admin(worktree).or_else(|_| {
        let candidates = fs::read_dir(repository.common_dir().join("worktrees"))
            .map_err(|_| CoreError::InvalidArgument)?;
        for candidate in candidates.flatten() {
            let gitdir = fs::read_to_string(candidate.path().join("gitdir")).unwrap_or_default();
            if gitdir.trim() == worktree.join(".git").to_string_lossy() {
                return Ok(candidate.path());
            }
        }
        Err(CoreError::InvalidArgument)
    })?;
    atomic_write(
        &worktree.join(".git"),
        format!("gitdir: {}\n", admin.display()).as_bytes(),
    )?;
    atomic_write(
        &admin.join("gitdir"),
        format!("{}\n", worktree.join(".git").display()).as_bytes(),
    )?;
    Ok(json!({"success": true}))
}

fn upstream_branch(root: &Path) -> Result<Value, CoreError> {
    let repository = discover(root)?;
    let Some(branch) = current_branch(&repository)? else {
        return Ok(json!({"branch": null, "upstream": null}));
    };
    let merge = config_string(&repository, &format!("branch.{branch}.merge"))?;
    let remote = config_string(&repository, &format!("branch.{branch}.remote"))?;
    let upstream = match (remote, merge) {
        (Some(remote), Some(merge)) if remote != "." => {
            let leaf = merge.strip_prefix("refs/heads/").unwrap_or(&merge);
            Some(json!({"branch": format!("{remote}/{leaf}")}))
        }
        (_, Some(merge)) => Some(json!({
            "branch": merge.strip_prefix("refs/heads/").unwrap_or(&merge)
        })),
        _ => None,
    };
    Ok(json!({"branch": branch, "upstream": upstream}))
}

fn default_branch(root: &Path) -> Result<Value, CoreError> {
    let repository = discover(root)?;
    for remote in repository.remote_names().iter() {
        let remote = remote
            .as_bstr()
            .to_str()
            .map_err(|_| CoreError::InvalidArgument)?;
        let reference_name = format!("refs/remotes/{remote}/HEAD");
        if let Some(reference) = repository
            .try_find_reference(reference_name.as_str())
            .map_err(|_| CoreError::InvalidArgument)?
        {
            if let gix::refs::TargetRef::Symbolic(target) = reference.target() {
                let target = target
                    .as_bstr()
                    .to_str()
                    .map_err(|_| CoreError::InvalidArgument)?;
                if let Some(branch) = target.rsplit('/').next() {
                    return Ok(json!({"branch": branch}));
                }
            }
        }
    }
    for branch in ["main", "master"] {
        if repository
            .try_find_reference(format!("refs/heads/{branch}").as_str())
            .map_err(|_| CoreError::InvalidArgument)?
            .is_some()
        {
            return Ok(json!({"branch": branch}));
        }
    }
    Ok(json!({"branch": null}))
}

fn base_branch(root: &Path) -> Result<Value, CoreError> {
    let repository = discover(root)?;
    let Some(branch) = current_branch(&repository)? else {
        return Ok(json!({"local": null, "remote": null}));
    };
    let local = config_string(&repository, &format!("branch.{branch}.merge"))?.map(|value| {
        value
            .strip_prefix("refs/heads/")
            .unwrap_or(&value)
            .to_owned()
    });
    let remote = config_string(&repository, &format!("branch.{branch}.remote"))?;
    Ok(json!({"local": local, "remote": remote}))
}

fn branch_metadata(cwd: &Path) -> Result<Value, CoreError> {
    let repository = match gix::discover(cwd) {
        Ok(repository) => repository,
        Err(_) => {
            return Ok(json!({
                "gitRoot": null,
                "branch": null,
                "baseBranch": null,
                "baseBranchRemote": null
            }));
        }
    };
    let root = repository
        .workdir()
        .ok_or(CoreError::InvalidArgument)?
        .to_string_lossy()
        .into_owned();
    let branch = current_branch(&repository)?;
    let (base, remote) = if let Some(branch) = branch.as_deref() {
        let base = config_string(&repository, &format!("branch.{branch}.merge"))?.map(|value| {
            value
                .strip_prefix("refs/heads/")
                .unwrap_or(&value)
                .to_owned()
        });
        let remote = config_string(&repository, &format!("branch.{branch}.remote"))?;
        (base, remote)
    } else {
        (None, None)
    };
    Ok(json!({
        "gitRoot": root,
        "branch": branch,
        "baseBranch": base,
        "baseBranchRemote": remote,
    }))
}

fn git_origins(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let dirs = params
        .get("dirs")
        .and_then(Value::as_array)
        .ok_or(CoreError::InvalidArgument)?;
    let mut seen = BTreeSet::new();
    let mut origins = Vec::new();
    for dir in dirs {
        let Some(dir) = dir
            .as_str()
            .filter(|value| !value.is_empty() && !value.contains('\0'))
        else {
            continue;
        };
        let standardized = Path::new(dir).components().collect::<std::path::PathBuf>();
        if !seen.insert(standardized) {
            continue;
        }
        let Ok(repository) = gix::discover(dir) else {
            continue;
        };
        let Some(root) = repository.workdir() else {
            continue;
        };
        origins.push(json!({
            "dir": dir,
            "root": root.to_string_lossy(),
            "originUrl": config_string(&repository, "remote.origin.url")?,
            "commonDir": repository.common_dir().to_string_lossy(),
        }));
    }
    Ok(json!({"origins": origins}))
}

fn index_info(cwd: &Path) -> Result<Value, CoreError> {
    let repository = match gix::discover(cwd) {
        Ok(repository) => repository,
        Err(_) => return Ok(json!({"lastModified": 0})),
    };
    let modified = fs::metadata(repository.git_dir().join("index"))
        .and_then(|metadata| metadata.modified())
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map(|duration| duration.as_secs_f64() * 1_000.0)
        .unwrap_or(0.0);
    Ok(json!({"lastModified": modified}))
}

fn submodule_paths(root: &Path) -> Result<Value, CoreError> {
    let repository = discover(root)?;
    let Some(workdir) = repository.workdir() else {
        return Ok(json!({"paths": []}));
    };
    let contents = match fs::read_to_string(workdir.join(".gitmodules")) {
        Ok(contents) => contents,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(json!({"paths": []}));
        }
        Err(_) => return Err(CoreError::InvalidArgument),
    };
    let mut seen = BTreeSet::new();
    let paths = contents
        .lines()
        .filter_map(|line| {
            let line = line.trim();
            let (key, value) = line.split_once('=')?;
            if key.trim() != "path" {
                return None;
            }
            let value = value.trim();
            (!value.is_empty() && seen.insert(value.to_owned())).then(|| value.to_owned())
        })
        .collect::<Vec<_>>();
    Ok(json!({"paths": paths}))
}

fn bounded_limit(
    params: &serde_json::Map<String, Value>,
    default_value: usize,
    maximum: usize,
) -> Result<usize, CoreError> {
    let value = params
        .get("limit")
        .and_then(Value::as_u64)
        .map(usize::try_from)
        .transpose()
        .map_err(|_| CoreError::InvalidArgument)?
        .unwrap_or(default_value);
    (value > 0 && value <= maximum)
        .then_some(value)
        .ok_or(CoreError::InvalidArgument)
}

fn branch_references(repository: &gix::Repository) -> Result<Vec<(String, i64)>, CoreError> {
    let platform = repository
        .references()
        .map_err(|_| CoreError::InvalidArgument)?;
    let iterator = platform
        .all()
        .map_err(|_| CoreError::InvalidArgument)?
        .peeled()
        .map_err(|_| CoreError::InvalidArgument)?;
    let mut branches = Vec::new();
    for reference in iterator {
        let reference = reference.map_err(|_| CoreError::InvalidArgument)?;
        let name = reference
            .name()
            .as_bstr()
            .to_str()
            .map_err(|_| CoreError::InvalidArgument)?;
        if !name.starts_with("refs/heads/") && !name.starts_with("refs/remotes/") {
            continue;
        }
        if name.ends_with("/HEAD") {
            continue;
        }
        let timestamp = reference
            .try_id()
            .and_then(|id| repository.find_commit(id.detach()).ok())
            .and_then(|commit| commit.time().ok())
            .map(|time| time.seconds)
            .unwrap_or(i64::MIN);
        branches.push((name.to_owned(), timestamp));
    }
    branches.sort_by(|left, right| right.1.cmp(&left.1).then_with(|| left.0.cmp(&right.0)));
    Ok(branches)
}

fn recent_branches(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let repository = discover(required_path(params, "root")?)?;
    let limit = bounded_limit(params, 10, 100)?;
    let branches = branch_references(&repository)?
        .into_iter()
        .take(limit)
        .map(|(name, _)| {
            name.strip_prefix("refs/heads/")
                .or_else(|| name.strip_prefix("refs/remotes/"))
                .unwrap_or(&name)
                .to_owned()
        })
        .collect::<Vec<_>>();
    Ok(json!({"branches": branches}))
}

fn search_branches(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let repository = discover(required_path(params, "root")?)?;
    let query = required_string(params, "query")?.to_lowercase();
    let terms = query.split_whitespace().collect::<Vec<_>>();
    let limit = bounded_limit(params, 20, 20)?;
    let preserve_remote_refs = params
        .get("preserveRemoteRefs")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let mut local = Vec::new();
    let mut remote = Vec::new();
    let mut seen = BTreeSet::new();
    for (reference, _) in branch_references(&repository)? {
        let (is_remote, name) = if let Some(name) = reference.strip_prefix("refs/heads/") {
            (false, name)
        } else if let Some(name) = reference.strip_prefix("refs/remotes/") {
            (true, name)
        } else {
            continue;
        };
        if !terms.iter().all(|term| name.to_lowercase().contains(term)) {
            continue;
        }
        let display = if is_remote && !preserve_remote_refs {
            name.split_once('/')
                .map(|(_, branch)| branch)
                .unwrap_or(name)
        } else {
            name
        };
        if !seen.insert(display.to_owned()) {
            continue;
        }
        if is_remote {
            remote.push(display.to_owned());
        } else {
            local.push(display.to_owned());
        }
    }
    let local = local.into_iter().take(limit).collect::<Vec<_>>();
    let remaining = limit.saturating_sub(local.len());
    let remote = remote.into_iter().take(remaining).collect::<Vec<_>>();
    if preserve_remote_refs {
        Ok(json!({"branches": local, "remoteBranchRefs": remote}))
    } else {
        Ok(json!({
            "branches": local.into_iter().chain(remote).collect::<Vec<_>>(),
            "remoteBranchRefs": []
        }))
    }
}

fn reference_commit(
    repository: &gix::Repository,
    name: &str,
) -> Result<Option<gix::hash::ObjectId>, CoreError> {
    let Some(mut reference) = repository
        .try_find_reference(name)
        .map_err(|_| CoreError::InvalidArgument)?
    else {
        return Ok(None);
    };
    let commit = reference
        .peel_to_commit()
        .map_err(|_| CoreError::InvalidArgument)?;
    Ok(Some(commit.id().detach()))
}

fn resolve_branch_commit(
    repository: &gix::Repository,
    branch: &str,
) -> Result<Option<gix::hash::ObjectId>, CoreError> {
    let names = if branch.starts_with("refs/") {
        vec![branch.to_owned()]
    } else if branch.contains('/') {
        vec![
            format!("refs/heads/{branch}"),
            format!("refs/remotes/{branch}"),
            format!("refs/remotes/origin/{branch}"),
        ]
    } else {
        vec![
            format!("refs/heads/{branch}"),
            format!("refs/remotes/origin/{branch}"),
        ]
    };
    for name in names {
        if let Some(id) = reference_commit(repository, &name)? {
            return Ok(Some(id));
        }
    }
    Ok(None)
}

fn configured_upstream(
    repository: &gix::Repository,
) -> Result<Option<gix::hash::ObjectId>, CoreError> {
    let Some(branch) = current_branch(repository)? else {
        return Ok(None);
    };
    let Some(merge) = config_string(repository, &format!("branch.{branch}.merge"))? else {
        return Ok(None);
    };
    let remote = config_string(repository, &format!("branch.{branch}.remote"))?
        .unwrap_or_else(|| ".".to_owned());
    let leaf = merge.strip_prefix("refs/heads/").unwrap_or(&merge);
    let reference = if remote == "." {
        format!("refs/heads/{leaf}")
    } else {
        format!("refs/remotes/{remote}/{leaf}")
    };
    reference_commit(repository, &reference)
}

fn branch_ahead_count(root: &Path) -> Result<Value, CoreError> {
    let repository = discover(root)?;
    let Some(upstream) = configured_upstream(&repository)? else {
        return Ok(json!({"commitsAhead": 0}));
    };
    let head = repository
        .head_id()
        .map_err(|_| CoreError::InvalidArgument)?
        .detach();
    let mut count = 0usize;
    for info in repository
        .find_commit(head)
        .map_err(|_| CoreError::InvalidArgument)?
        .ancestors()
        .with_hidden([upstream])
        .all()
        .map_err(|_| CoreError::InvalidArgument)?
    {
        info.map_err(|_| CoreError::InvalidArgument)?;
        count = count.saturating_add(1);
        if count > 100_000 {
            return Err(CoreError::InvalidArgument);
        }
    }
    Ok(json!({"commitsAhead": count}))
}

fn branch_commits(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let repository = discover(required_path(params, "root")?)?;
    let base = required_string(params, "baseBranch")?;
    let Some(base) = resolve_branch_commit(&repository, base)? else {
        return Ok(json!({"commits": []}));
    };
    let head = repository
        .head_id()
        .map_err(|_| CoreError::InvalidArgument)?
        .detach();
    let mut commits = Vec::new();
    for info in repository
        .find_commit(head)
        .map_err(|_| CoreError::InvalidArgument)?
        .ancestors()
        .with_hidden([base])
        .all()
        .map_err(|_| CoreError::InvalidArgument)?
        .take(100)
    {
        let info = info.map_err(|_| CoreError::InvalidArgument)?;
        let commit = repository
            .find_commit(info.id)
            .map_err(|_| CoreError::InvalidArgument)?;
        let message = utf8(
            commit
                .message_raw()
                .map_err(|_| CoreError::InvalidArgument)?
                .as_bytes(),
        )?;
        let subject = commit
            .message()
            .map_err(|_| CoreError::InvalidArgument)?
            .summary()
            .to_str()
            .map_err(|_| CoreError::InvalidArgument)?
            .to_owned();
        let committed_at = commit
            .time()
            .map_err(|_| CoreError::InvalidArgument)?
            .format_or_unix(gix::date::time::format::ISO8601_STRICT);
        commits.push(json!({
            "sha": info.id.to_string(),
            "committedAt": committed_at,
            "subject": subject,
            "message": message,
        }));
    }
    Ok(json!({"commits": commits}))
}

fn successful_unified_diff(diff: String) -> Value {
    json!({
        "type": "success",
        "unifiedDiffBytes": diff.len(),
        "unifiedDiff": diff,
    })
}

fn commit_message_diff(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let cwd = required_path(params, "cwd")?;
    let source = if params
        .get("includeUnstaged")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        "uncommitted"
    } else {
        "staged"
    };
    let diff =
        git_diff::unified_diff(cwd, source, None, None).map_err(|_| CoreError::InvalidArgument)?;
    Ok(successful_unified_diff(diff))
}

fn review_patch(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let cwd = required_path(params, "cwd")?;
    let source = required_string(params, "source")?;
    let commit_sha = params.get("commitSha").and_then(Value::as_str);
    let base_branch = params.get("baseBranch").and_then(Value::as_str);
    let diff = git_diff::unified_diff(cwd, source, commit_sha, base_branch)
        .map_err(|_| CoreError::InvalidArgument)?;
    Ok(json!({
        "source": source,
        "diff": successful_unified_diff(diff),
    }))
}

fn review_diff(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let cwd = required_path(params, "cwd")?;
    let source = required_string(params, "source")?;
    let files = params
        .get("files")
        .and_then(Value::as_array)
        .ok_or(CoreError::InvalidArgument)?;
    let paths = files
        .iter()
        .filter_map(|file| {
            let file = file.as_object()?;
            let path = file.get("path")?.as_str()?;
            if !safe_relative_path(path) {
                return None;
            }
            let previous = file
                .get("previousPath")
                .and_then(Value::as_str)
                .filter(|path| safe_relative_path(path))
                .map(str::to_owned);
            Some((path.to_owned(), previous))
        })
        .collect::<Vec<_>>();
    let diffs = git_diff::file_diffs(
        cwd,
        source,
        params.get("commitSha").and_then(Value::as_str),
        params.get("baseBranch").and_then(Value::as_str),
        &paths,
    )
    .map_err(|_| CoreError::InvalidArgument)?
    .into_iter()
    .map(|(path, diff)| {
        let bytes = diff.len();
        (
            path,
            json!({
                "type": "success",
                "diff": diff,
                "diffBytes": bytes,
            }),
        )
    })
    .collect::<serde_json::Map<_, _>>();
    Ok(json!({
        "type": "success",
        "source": source,
        "diffs": diffs,
    }))
}

fn parse_hunk_range(line: &str) -> Option<(usize, usize)> {
    let body = line.strip_prefix("@@ -")?;
    let (deletion, body) = body.split_once(" +")?;
    let (addition, _) = body.split_once(" @@")?;
    fn range(value: &str) -> Option<(usize, usize)> {
        let (start, count) = value
            .split_once(',')
            .map(|(start, count)| (start, count))
            .unwrap_or((value, "1"));
        Some((start.parse().ok()?, count.parse().ok()?))
    }
    let (deletion_start, deletion_count) = range(deletion)?;
    let (addition_start, addition_count) = range(addition)?;
    let start = deletion_start.min(addition_start).max(1);
    let end = deletion_start
        .saturating_add(deletion_count.saturating_sub(1))
        .max(addition_start.saturating_add(addition_count.saturating_sub(1)))
        .max(start);
    Some((start, end))
}

fn append_search_matches(
    matches: &mut Vec<Value>,
    total: &mut usize,
    text: &str,
    query: &str,
    path: &str,
    hunk_id: &str,
    offset: usize,
    line_start: usize,
    line_end: usize,
) {
    const CAP: usize = 250;
    let lowered = text.to_lowercase();
    let mut search_start = 0;
    while search_start < lowered.len() {
        let Some(relative_start) = lowered[search_start..].find(query) else {
            break;
        };
        let start = search_start + relative_start;
        let end = start + query.len();
        *total += 1;
        if matches.len() < CAP {
            let before_start = start.saturating_sub(24);
            let after_end = end.saturating_add(24).min(text.len());
            let boundary = |mut index: usize| {
                while index > 0 && !text.is_char_boundary(index) {
                    index -= 1;
                }
                index
            };
            let start = boundary(start);
            let end = boundary(end);
            let before_start = boundary(before_start);
            let after_end = boundary(after_end);
            matches.push(json!({
                "path": path,
                "hunkId": hunk_id,
                "lineStart": line_start,
                "lineEnd": line_end,
                "start": offset + start,
                "end": offset + end,
                "snippet": {
                    "before": &text[before_start..start],
                    "match": &text[start..end],
                    "after": &text[end..after_end],
                }
            }));
        }
        search_start = end.max(search_start + 1);
    }
}

fn review_search(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let cwd = required_path(params, "cwd")?;
    let source = required_string(params, "source")?;
    let query = required_string(params, "query")?.trim();
    if query.is_empty() {
        return Ok(json!({
            "type": "success",
            "source": source,
            "query": query,
            "matches": [],
            "totalMatches": 0,
            "isCapped": false,
        }));
    }
    let diff = git_diff::unified_diff(
        cwd,
        source,
        params.get("commitSha").and_then(Value::as_str),
        params.get("baseBranch").and_then(Value::as_str),
    )
    .map_err(|_| CoreError::InvalidArgument)?;
    let query_lower = query.to_lowercase();
    let mut path: Option<String> = None;
    let mut hunk_id: Option<String> = None;
    let mut hunk_sequence = 0usize;
    let mut line_start = 1usize;
    let mut line_end = 1usize;
    let mut offset = 0usize;
    let mut matches = Vec::new();
    let mut total = 0usize;
    for line in diff.split('\n') {
        if let Some(rest) = line.strip_prefix("diff --git ") {
            let fields = rest.split_whitespace().collect::<Vec<_>>();
            if fields.len() >= 2 {
                let old_path = fields[0].strip_prefix("a/").unwrap_or(fields[0]);
                let new_path = fields[1].strip_prefix("b/").unwrap_or(fields[1]);
                path = Some(new_path.to_owned());
                hunk_id = None;
                offset = 0;
                let display = if old_path == new_path {
                    new_path.to_owned()
                } else {
                    format!("{old_path} -> {new_path}")
                };
                append_search_matches(
                    &mut matches,
                    &mut total,
                    &display,
                    &query_lower,
                    new_path,
                    "path",
                    0,
                    1,
                    1,
                );
            }
            continue;
        }
        if let Some((start, end)) = parse_hunk_range(line) {
            line_start = start;
            line_end = end;
            hunk_id = Some(hunk_sequence.to_string());
            hunk_sequence += 1;
            offset = 0;
            continue;
        }
        let Some(current_path) = path.as_deref() else {
            continue;
        };
        let Some(current_hunk) = hunk_id.as_deref() else {
            continue;
        };
        let Some(prefix) = line.as_bytes().first() else {
            continue;
        };
        if !matches!(*prefix, b' ' | b'+' | b'-')
            || line.starts_with("+++")
            || line.starts_with("---")
        {
            continue;
        }
        let text = &line[1..];
        append_search_matches(
            &mut matches,
            &mut total,
            text,
            &query_lower,
            current_path,
            current_hunk,
            offset,
            line_start,
            line_end,
        );
        offset = offset.saturating_add(text.len() + 1);
    }
    Ok(json!({
        "type": "success",
        "source": source,
        "query": query,
        "matches": matches,
        "totalMatches": total,
        "isCapped": total > 250,
    }))
}

fn branch_diff_stats(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let cwd = required_path(params, "cwd")?;
    let diff = git_diff::unified_diff(
        cwd,
        "branch",
        None,
        params.get("baseBranch").and_then(Value::as_str),
    )
    .map_err(|_| CoreError::InvalidArgument)?;
    let (additions, deletions, file_count) = unified_diff_stats(&diff);
    Ok(json!({
        "additions": additions,
        "deletions": deletions,
        "fileCount": file_count,
    }))
}

fn unified_diff_stats(diff: &str) -> (usize, usize, usize) {
    let mut additions = 0usize;
    let mut deletions = 0usize;
    let mut files = BTreeSet::new();
    let mut current_path = None;
    for line in diff.split('\n') {
        if let Some(rest) = line.strip_prefix("diff --git ") {
            let fields = rest.split_whitespace().collect::<Vec<_>>();
            current_path = fields
                .get(1)
                .map(|path| path.strip_prefix("b/").unwrap_or(path).to_string());
            if let Some(path) = current_path.as_ref() {
                files.insert(path.clone());
            }
        } else if current_path.is_some() && line.starts_with('+') && !line.starts_with("+++") {
            additions += 1;
        } else if current_path.is_some() && line.starts_with('-') && !line.starts_with("---") {
            deletions += 1;
        }
    }
    (additions, deletions, files.len())
}

fn review_summary(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let cwd = required_path(params, "cwd")?;
    let source = required_string(params, "source")?;
    let requested_paths = params
        .get("paths")
        .and_then(Value::as_array)
        .map(|paths| {
            paths
                .iter()
                .filter_map(Value::as_str)
                .filter(|path| safe_relative_path(path))
                .map(str::to_owned)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    git_diff::review_summary(
        cwd,
        source,
        params.get("commitSha").and_then(Value::as_str),
        params.get("baseBranch").and_then(Value::as_str),
        &requested_paths,
        params
            .get("includeUntrackedFiles")
            .and_then(Value::as_bool)
            .unwrap_or(true),
    )
    .map_err(|_| CoreError::InvalidArgument)
}

fn github_login(email: &str) -> Option<&str> {
    let email = email.trim_matches(|character| matches!(character, '<' | '>' | ' '));
    let local = email.strip_suffix("@users.noreply.github.com")?;
    Some(
        local
            .split_once('+')
            .filter(|(prefix, _)| prefix.chars().all(|character| character.is_ascii_digit()))
            .map(|(_, login)| login)
            .unwrap_or(local),
    )
}

fn repository_web_url(repository: &gix::Repository) -> Result<Option<String>, CoreError> {
    let Some(mut value) = config_string(repository, "remote.origin.url")? else {
        return Ok(None);
    };
    if value.ends_with(".git") {
        value.truncate(value.len() - 4);
    }
    if let Some(value) = value.strip_prefix("git@") {
        let Some((host, path)) = value.split_once(':') else {
            return Ok(None);
        };
        if host == "github.com" || host.ends_with(".github.com") {
            return Ok(Some(format!("https://{host}/{path}")));
        }
        return Ok(None);
    }
    let Some(value) = value.strip_prefix("https://") else {
        return Ok(None);
    };
    let host = value.split('/').next().unwrap_or_default();
    if host == "github.com" || host.ends_with(".github.com") {
        Ok(Some(format!("https://{value}")))
    } else {
        Ok(None)
    }
}

fn blame_file(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let cwd = required_path(params, "cwd")?;
    let path = required_string(params, "path")?;
    if !safe_relative_path(path) {
        return Ok(json!({"type": "error", "error": {"type": "not-found"}}));
    }
    let repository = discover(cwd)?;
    let head = repository
        .head_id()
        .map_err(|_| CoreError::InvalidArgument)?
        .detach();
    let outcome = match repository.blame_file(
        path.into(),
        head,
        gix::repository::blame_file::Options::default(),
    ) {
        Ok(outcome) => outcome,
        Err(_) => return Ok(json!({"type": "error", "error": {"type": "not-found"}})),
    };
    let mut lines = Vec::new();
    for entry in outcome.entries {
        let commit = repository
            .find_commit(entry.commit_id)
            .map_err(|_| CoreError::InvalidArgument)?;
        let author = commit.author().map_err(|_| CoreError::InvalidArgument)?;
        let author_name = author
            .name
            .to_str()
            .ok()
            .filter(|value| !value.is_empty())
            .map(str::to_owned);
        let email = author.email.to_str().ok();
        let login = email.and_then(github_login).map(str::to_owned);
        let author_time = author
            .time()
            .map_err(|_| CoreError::InvalidArgument)?
            .seconds;
        let summary = commit
            .message()
            .ok()
            .and_then(|message| message.summary().to_str().ok().map(str::to_owned));
        for index in 0..entry.len.get() {
            lines.push(json!({
                "author": author_name,
                "authorLogin": login,
                "authorTime": author_time,
                "commitSha": entry.commit_id.to_string(),
                "lineNumber": entry.start_in_blamed_file + index + 1,
                "summary": summary,
            }));
        }
    }
    Ok(json!({
        "type": "success",
        "lines": lines,
        "repositoryWebUrl": repository_web_url(&repository)?,
    }))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SyncedBranchConfig {
    branch: String,
    last_synced_tree_ref: String,
}

fn synced_branch_config(repository: &gix::Repository) -> Option<SyncedBranchConfig> {
    let data = fs::read(repository.git_dir().join("codex-synced-branch.json")).ok()?;
    let config: SyncedBranchConfig = serde_json::from_slice(&data).ok()?;
    (!config.branch.is_empty() && !config.last_synced_tree_ref.is_empty()).then_some(config)
}

fn synced_branch(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let repository = discover(required_path(params, "cwd")?)?;
    let Some(config) = synced_branch_config(&repository) else {
        return Ok(json!({
            "branch": null,
            "base": null,
            "hasConflicts": false,
        }));
    };
    let index = repository
        .index_or_empty()
        .map_err(|_| CoreError::InvalidArgument)?;
    let has_conflicts = index
        .entries()
        .iter()
        .any(|entry| entry.stage() != gix::index::entry::Stage::Unconflicted);
    Ok(json!({
        "branch": config.branch.strip_prefix("refs/heads/").unwrap_or(&config.branch),
        "base": config.last_synced_tree_ref,
        "hasConflicts": has_conflicts,
    }))
}

fn unique_commit_count(
    repository: &gix::Repository,
    tip: gix::hash::ObjectId,
    hidden: gix::hash::ObjectId,
) -> Result<usize, CoreError> {
    let mut count = 0usize;
    for info in repository
        .find_commit(tip)
        .map_err(|_| CoreError::InvalidArgument)?
        .ancestors()
        .with_hidden([hidden])
        .all()
        .map_err(|_| CoreError::InvalidArgument)?
    {
        info.map_err(|_| CoreError::InvalidArgument)?;
        count += 1;
        if count > 100_000 {
            return Err(CoreError::InvalidArgument);
        }
    }
    Ok(count)
}

fn diff_stat_envelope(cwd: &Path, head: gix::hash::ObjectId) -> Result<Value, CoreError> {
    let diff = git_diff::unified_diff(cwd, "uncommitted", None, None)
        .map_err(|_| CoreError::InvalidArgument)?;
    let (additions, deletions, file_count) = unified_diff_stats(&diff);
    Ok(json!({
        "leftRef": head.to_string(),
        "rightRef": if file_count == 0 { head.to_string() } else { "WORKTREE".to_owned() },
        "filesChanged": file_count,
        "linesAdded": additions,
        "linesRemoved": deletions,
    }))
}

fn linked_worktree_for_branch(
    repository: &gix::Repository,
    branch: &str,
) -> Option<std::path::PathBuf> {
    let entries = fs::read_dir(repository.common_dir().join("worktrees")).ok()?;
    for entry in entries.flatten() {
        let administrative = entry.path();
        let Ok(head) = fs::read_to_string(administrative.join("HEAD")) else {
            continue;
        };
        if head.trim() != format!("ref: {branch}") {
            continue;
        }
        let Ok(git_file) = fs::read_to_string(administrative.join("gitdir")) else {
            continue;
        };
        let Some(root) = Path::new(git_file.trim()).parent() else {
            continue;
        };
        if root.is_dir() {
            return Some(root.to_owned());
        }
    }
    None
}

fn synced_branch_state(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let repository = discover(required_path(params, "cwd")?)?;
    let config = synced_branch_config(&repository).ok_or(CoreError::InvalidArgument)?;
    let root = repository
        .workdir()
        .ok_or(CoreError::InvalidArgument)?
        .to_owned();
    let head = repository
        .head_id()
        .map_err(|_| CoreError::InvalidArgument)?
        .detach();
    let branch_head =
        reference_commit(&repository, &config.branch)?.ok_or(CoreError::InvalidArgument)?;
    let checked_out_root = if repository
        .head_name()
        .ok()
        .flatten()
        .is_some_and(|name| name.as_bstr().as_bytes() == config.branch.as_bytes())
    {
        Some(root.clone())
    } else {
        linked_worktree_for_branch(&repository, &config.branch)
    };
    let local_stats = match checked_out_root.as_deref() {
        Some(branch_root) if branch_root != root => diff_stat_envelope(branch_root, branch_head)?,
        _ => json!({
            "leftRef": branch_head.to_string(),
            "rightRef": branch_head.to_string(),
            "filesChanged": 0,
            "linesAdded": 0,
            "linesRemoved": 0,
        }),
    };
    let branch_snapshot = if let Some(checked_out_root) = checked_out_root {
        json!({
            "checkedOut": true,
            "snapshot": {
                "root": checked_out_root.to_string_lossy(),
                "headCommitSha": branch_head.to_string(),
            },
        })
    } else {
        json!({
            "checkedOut": false,
            "headCommitSha": branch_head.to_string(),
        })
    };
    Ok(json!({
        "branch": config.branch,
        "worktreeSnapshot": {
            "root": root.to_string_lossy(),
            "headCommitSha": head.to_string(),
        },
        "branchSnapshot": branch_snapshot,
        "localCommitsAhead": unique_commit_count(&repository, branch_head, head)?,
        "worktreeCommitsAhead": unique_commit_count(&repository, head, branch_head)?,
        "localUncommittedDiffStats": local_stats,
        "worktreeUncommittedDiffStats": diff_stat_envelope(&root, head)?,
    }))
}

fn standardized_path(path: &Path) -> std::path::PathBuf {
    let mut output = std::path::PathBuf::new();
    for component in path.components() {
        match component {
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => {
                output.pop();
            }
            component => output.push(component.as_os_str()),
        }
    }
    output
}

fn snapshot_identity(worktree_path: &Path) -> (String, String) {
    let path = standardized_path(worktree_path)
        .to_string_lossy()
        .into_owned();
    let worktree_id = format!("{:x}", Sha1::digest(path.as_bytes()));
    let snapshot_ref = format!("refs/codex/snapshots/{worktree_id}");
    (worktree_id, snapshot_ref)
}

fn candidate_paths(
    params: &serde_json::Map<String, Value>,
) -> Result<Vec<std::path::PathBuf>, CoreError> {
    let values = params
        .get("candidateRoots")
        .and_then(Value::as_array)
        .ok_or(CoreError::InvalidArgument)?;
    Ok(values
        .iter()
        .filter_map(Value::as_str)
        .map(std::path::PathBuf::from)
        .filter(|path| path.is_dir())
        .collect())
}

fn inspect_worktree_snapshot(
    candidate_roots: &[std::path::PathBuf],
    worktree_path: &Path,
) -> Result<Value, CoreError> {
    let (worktree_id, snapshot_ref) = snapshot_identity(worktree_path);
    let mut valid_repository_found = false;
    for candidate in candidate_roots {
        let Ok(repository) = gix::discover(candidate) else {
            continue;
        };
        let Some(root) = repository.workdir() else {
            continue;
        };
        valid_repository_found = true;
        let Some(mut reference) = repository
            .try_find_reference(snapshot_ref.as_str())
            .map_err(|_| CoreError::InvalidArgument)?
        else {
            continue;
        };
        let commit = reference
            .peel_to_commit()
            .map_err(|_| CoreError::InvalidArgument)?;
        return Ok(json!({
            "snapshotRef": snapshot_ref,
            "worktreeId": worktree_id,
            "repoRoot": root.to_string_lossy(),
            "commonDir": repository.common_dir().to_string_lossy(),
            "exists": true,
            "commitSha": commit.id().to_string(),
        }));
    }
    if !valid_repository_found {
        return Err(CoreError::InvalidArgument);
    }
    Ok(json!({
        "snapshotRef": snapshot_ref,
        "worktreeId": worktree_id,
        "exists": false,
        "commitSha": null,
    }))
}

fn worktree_snapshot_ref(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let candidate_roots = candidate_paths(params)?;
    if candidate_roots.is_empty() {
        return Err(CoreError::InvalidArgument);
    }
    inspect_worktree_snapshot(&candidate_roots, required_path(params, "worktreePath")?)
}

fn managed_worktree_state(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let cwd = required_path(params, "cwd")?;
    let worktree_path = required_path(params, "worktreePath")?;
    if cwd.is_dir() {
        return Ok(json!({"kind": "available"}));
    }
    if cwd != worktree_path && worktree_path.is_dir() {
        return Ok(json!({"kind": "gone"}));
    }
    let candidate_roots = candidate_paths(params)?;
    if candidate_roots.is_empty() {
        return Ok(json!({
            "kind": "unavailable",
            "reason": "no-candidate-roots",
        }));
    }
    match inspect_worktree_snapshot(&candidate_roots, worktree_path) {
        Ok(snapshot) if snapshot["exists"] == true => Ok(json!({
            "kind": "restorable",
            "snapshot": snapshot,
        })),
        Ok(_) => Ok(json!({"kind": "gone"})),
        Err(_) => Ok(json!({
            "kind": "unavailable",
            "reason": "inspection-failed",
        })),
    }
}

fn encode_worktree(
    repository: &gix::Repository,
    root: &Path,
    head_text: Option<&str>,
    locked: bool,
    prunable: bool,
) -> Result<Value, CoreError> {
    let (sha, branch) = if let Some(head_text) = head_text {
        let head_text = head_text.trim();
        if let Some(reference) = head_text.strip_prefix("ref: ") {
            let sha = reference_commit(repository, reference)?
                .map(|id| id.to_string())
                .unwrap_or_default();
            (
                sha,
                reference
                    .strip_prefix("refs/heads/")
                    .unwrap_or(reference)
                    .to_owned(),
            )
        } else {
            (head_text.to_owned(), String::new())
        }
    } else {
        let sha = repository
            .head_id()
            .map_err(|_| CoreError::InvalidArgument)?
            .to_string();
        let branch = current_branch(repository)?.unwrap_or_default();
        (sha, branch)
    };
    let head_ref = if branch.is_empty() {
        json!({"sha": sha, "type": "detached"})
    } else {
        json!({"sha": sha, "type": "branch", "string": branch})
    };
    Ok(json!({
        "root": root.to_string_lossy(),
        "prunable": prunable,
        "locked": locked,
        "headRef": head_ref,
    }))
}

fn list_worktrees(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let repository = discover(required_path(params, "cwd")?)?;
    let root = repository
        .workdir()
        .ok_or(CoreError::InvalidArgument)?
        .to_owned();
    let mut worktrees = vec![encode_worktree(&repository, &root, None, false, false)?];
    let administrative_root = repository.common_dir().join("worktrees");
    let mut entries = fs::read_dir(&administrative_root)
        .ok()
        .into_iter()
        .flatten()
        .flatten()
        .collect::<Vec<_>>();
    entries.sort_by_key(|entry| entry.path());
    for entry in entries {
        let administrative = entry.path();
        let Ok(git_file) = fs::read_to_string(administrative.join("gitdir")) else {
            continue;
        };
        let Some(linked_root) = Path::new(git_file.trim()).parent() else {
            continue;
        };
        let head = fs::read_to_string(administrative.join("HEAD")).ok();
        worktrees.push(encode_worktree(
            &repository,
            linked_root,
            head.as_deref(),
            administrative.join("locked").exists(),
            !linked_root.is_dir(),
        )?);
    }
    Ok(json!({"worktrees": worktrees}))
}

fn codex_worktrees(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let root = params
        .get("worktreesRoot")
        .and_then(Value::as_str)
        .map(std::path::PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(std::path::PathBuf::from))
        .map(|path| {
            if params.get("worktreesRoot").is_some() {
                path
            } else {
                path.join(".codex/worktrees")
            }
        })
        .ok_or(CoreError::InvalidArgument)?;
    let mut parents: Vec<std::path::PathBuf> = match fs::read_dir(root) {
        Ok(entries) => entries.flatten().map(|entry| entry.path()).collect(),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Vec::new(),
        Err(_) => return Err(CoreError::InvalidArgument),
    };
    parents.sort();
    let mut worktrees = Vec::new();
    for parent in parents.into_iter().filter(|path| path.is_dir()) {
        let mut children: Vec<std::path::PathBuf> = match fs::read_dir(parent) {
            Ok(entries) => entries.flatten().map(|entry| entry.path()).collect(),
            Err(_) => continue,
        };
        children.sort();
        for child in children.into_iter().filter(|path| path.is_dir()) {
            let Ok(repository) = gix::discover(&child) else {
                continue;
            };
            worktrees.push(json!({
                "dir": child.to_string_lossy(),
                "gitDir": repository.git_dir().to_string_lossy(),
            }));
        }
    }
    Ok(json!({"worktrees": worktrees}))
}

fn repository_worktree_roots(
    repository: &gix::Repository,
) -> Result<Vec<std::path::PathBuf>, CoreError> {
    let mut roots = vec![
        repository
            .workdir()
            .ok_or(CoreError::InvalidArgument)?
            .to_owned(),
    ];
    let mut entries = fs::read_dir(repository.common_dir().join("worktrees"))
        .ok()
        .into_iter()
        .flatten()
        .flatten()
        .collect::<Vec<_>>();
    entries.sort_by_key(|entry| entry.path());
    for entry in entries {
        let Ok(git_file) = fs::read_to_string(entry.path().join("gitdir")) else {
            continue;
        };
        let Some(root) = Path::new(git_file.trim()).parent() else {
            continue;
        };
        if root.is_dir() && !roots.iter().any(|candidate| candidate == root) {
            roots.push(root.to_owned());
        }
    }
    Ok(roots)
}

fn set_worktree_owner_thread(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let worktree = required_path(params, "worktree")?;
    let conversation_id = required_string(params, "conversationId")?;
    let repository = discover(worktree)?;
    let destination = repository.git_dir().join("codex-thread.json");
    fs::create_dir_all(repository.git_dir()).map_err(|_| CoreError::InvalidArgument)?;
    let temporary = repository
        .git_dir()
        .join(format!(".codex-thread-{}.tmp", std::process::id()));
    let contents = serde_json::to_vec_pretty(&json!({
        "version": 1,
        "ownerThreadId": conversation_id,
    }))
    .map_err(|_| CoreError::InvalidJson)?;
    let mut contents_with_newline = contents;
    contents_with_newline.push(b'\n');
    fs::write(&temporary, contents_with_newline).map_err(|_| CoreError::InvalidArgument)?;
    fs::rename(&temporary, destination).map_err(|_| CoreError::InvalidArgument)?;
    Ok(json!({"success": true}))
}

fn resolve_worktree_for_thread(
    params: &serde_json::Map<String, Value>,
) -> Result<Value, CoreError> {
    let repository = discover(required_path(params, "cwd")?)?;
    let conversation_id = required_string(params, "conversationId")?;
    let mut matches = Vec::new();
    for root in repository_worktree_roots(&repository)? {
        let Ok(worktree_repository) = gix::discover(&root) else {
            continue;
        };
        let Ok(data) = fs::read(worktree_repository.git_dir().join("codex-thread.json")) else {
            continue;
        };
        let Ok(config) = serde_json::from_slice::<Value>(&data) else {
            continue;
        };
        if config["version"] != 1 || config["ownerThreadId"] != conversation_id {
            continue;
        }
        let modified = fs::metadata(&root)
            .and_then(|metadata| metadata.modified())
            .ok()
            .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
            .map(|duration| duration.as_nanos())
            .unwrap_or(0);
        matches.push((modified, root));
    }
    matches.sort_by(|left, right| left.0.cmp(&right.0).then_with(|| left.1.cmp(&right.1)));
    let Some((_, root)) = matches.pop() else {
        return Ok(json!({
            "worktreeGitRoot": null,
            "worktreeWorkspaceRoot": null,
            "hasUncommittedChanges": false,
        }));
    };
    let counts = git_diff::status_counts(&root, true).map_err(|_| CoreError::InvalidArgument)?;
    Ok(json!({
        "worktreeGitRoot": root.to_string_lossy(),
        "worktreeWorkspaceRoot": root.to_string_lossy(),
        "hasUncommittedChanges": counts.staged + counts.unstaged + counts.untracked > 0,
    }))
}

fn safe_relative_path(path: &str) -> bool {
    let path = Path::new(path);
    !path.is_absolute()
        && !path.components().any(|component| {
            matches!(
                component,
                std::path::Component::ParentDir
                    | std::path::Component::RootDir
                    | std::path::Component::Prefix(_)
            )
        })
}

fn file_object_result(data: Vec<u8>, maximum: usize) -> Value {
    if data.len() > maximum {
        return json!({
            "type": "error",
            "error": {"type": "too-large", "limitBytes": maximum}
        });
    }
    let text = String::from_utf8_lossy(&data);
    let mut lines = text.split('\n').map(str::to_owned).collect::<Vec<_>>();
    if text.ends_with('\n') {
        lines.pop();
    }
    json!({"type": "success", "lines": lines})
}

fn not_found_object() -> Value {
    json!({"type": "error", "error": {"type": "not-found"}})
}

fn cat_file(params: &serde_json::Map<String, Value>) -> Result<Value, CoreError> {
    let cwd = required_path(params, "cwd")?;
    let requests = params
        .get("requests")
        .and_then(Value::as_array)
        .ok_or(CoreError::InvalidArgument)?;
    let maximum = params
        .get("maxObjectBytes")
        .and_then(Value::as_u64)
        .map(usize::try_from)
        .transpose()
        .map_err(|_| CoreError::InvalidArgument)?
        .unwrap_or(5 * 1_024 * 1_024);
    if maximum > 20 * 1_024 * 1_024 {
        return Err(CoreError::InvalidArgument);
    }
    if requests.len() > 4 {
        return Ok(Value::Array(
            requests.iter().map(|_| not_found_object()).collect(),
        ));
    }
    let repository = discover(cwd)?;
    let workdir = repository.workdir().map(Path::to_owned);
    let mut results = Vec::with_capacity(requests.len());
    for request in requests {
        let Some(request) = request.as_object() else {
            results.push(not_found_object());
            continue;
        };
        let object = request
            .get("oid")
            .and_then(Value::as_str)
            .filter(|oid| oid.len() == 40)
            .and_then(|oid| gix::hash::ObjectId::from_hex(oid.as_bytes()).ok())
            .and_then(|oid| repository.find_object(oid).ok())
            .map(|object| object.data.to_vec());
        if let Some(data) = object {
            results.push(file_object_result(data, maximum));
            continue;
        }
        let fallback = request
            .get("fallbackToDisk")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let path = request.get("path").and_then(Value::as_str);
        let disk = match (fallback, path, workdir.as_ref()) {
            (true, Some(path), Some(workdir)) if safe_relative_path(path) => {
                fs::read(workdir.join(path)).ok()
            }
            _ => None,
        };
        results.push(
            disk.map(|data| file_object_result(data, maximum))
                .unwrap_or_else(not_found_object),
        );
    }
    Ok(Value::Array(results))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::process::Command;
    use tempfile::TempDir;

    fn repository() -> TempDir {
        let directory = tempfile::tempdir().unwrap();
        for arguments in [
            vec!["init", "-b", "main"],
            vec!["config", "user.name", "Codex"],
            vec!["config", "user.email", "codex@example.invalid"],
        ] {
            assert!(
                Command::new("git")
                    .current_dir(directory.path())
                    .args(arguments)
                    .status()
                    .unwrap()
                    .success()
            );
        }
        fs::write(directory.path().join("tracked.txt"), "one\n").unwrap();
        assert!(
            Command::new("git")
                .current_dir(directory.path())
                .args(["add", "tracked.txt"])
                .status()
                .unwrap()
                .success()
        );
        assert!(
            Command::new("git")
                .current_dir(directory.path())
                .args(["commit", "-m", "initial"])
                .status()
                .unwrap()
                .success()
        );
        directory
    }

    fn call(method: &str, params: Value) -> Value {
        serde_json::from_slice(&request(&json!({"method": method, "params": params})).unwrap())
            .unwrap()
    }

    #[test]
    fn prepares_cloud_worktree_snapshot_tarball_without_git_metadata() {
        let directory = repository();
        fs::write(directory.path().join("untracked.txt"), "ipad snapshot\n").unwrap();
        assert!(
            Command::new("git")
                .current_dir(directory.path())
                .args([
                    "remote",
                    "add",
                    "origin",
                    "https://example.invalid/codex-ipad.git",
                ])
                .status()
                .unwrap()
                .success()
        );
        let snapshot = call(
            "prepare-worktree-snapshot",
            json!({
                "gitRoot": directory.path(),
                "snapshotBranch": "feature/ipad"
            }),
        );
        assert_eq!(
            snapshot["repoName"],
            directory.path().file_name().unwrap().to_str().unwrap()
        );
        assert_eq!(snapshot["contentType"], "application/gzip");
        assert_eq!(snapshot["snapshotBranch"], "feature/ipad");
        assert_eq!(
            snapshot["remotes"]["origin"],
            "https://example.invalid/codex-ipad.git"
        );
        assert_eq!(
            snapshot["commitSha"],
            Command::new("git")
                .current_dir(directory.path())
                .args(["rev-parse", "HEAD"])
                .output()
                .map(|output| String::from_utf8(output.stdout).unwrap().trim().to_owned())
                .unwrap()
        );
        let tarball_path = PathBuf::from(snapshot["tarballPath"].as_str().unwrap());
        assert_eq!(
            fs::metadata(&tarball_path).unwrap().len(),
            snapshot["tarballSize"].as_u64().unwrap()
        );
        let decoder = flate2::read::GzDecoder::new(fs::File::open(&tarball_path).unwrap());
        let mut archive = tar::Archive::new(decoder);
        let paths = archive
            .entries()
            .unwrap()
            .map(|entry| entry.unwrap().path().unwrap().into_owned())
            .collect::<Vec<_>>();
        assert!(paths.iter().any(|path| path == Path::new("tracked.txt")));
        assert!(paths.iter().any(|path| path == Path::new("untracked.txt")));
        assert!(!paths.iter().any(|path| path.starts_with(".git")));
        fs::remove_file(tarball_path).unwrap();
    }

    #[test]
    fn pushes_branch_to_local_bare_remote_and_sets_upstream() {
        let directory = repository();
        let remote = tempfile::tempdir().unwrap();
        assert!(
            Command::new("git")
                .current_dir(remote.path())
                .args(["init", "--bare"])
                .status()
                .unwrap()
                .success()
        );
        assert!(
            Command::new("git")
                .current_dir(directory.path())
                .args(["remote", "add", "origin", remote.path().to_str().unwrap(),])
                .status()
                .unwrap()
                .success()
        );

        let result = call(
            "git-push",
            json!({
                "cwd": directory.path(),
                "refspec": "main:main",
                "force": false,
                "setUpstream": true
            }),
        );
        assert_eq!(result["status"], "success", "{result}");
        assert!(
            result["execOutput"]
                .as_str()
                .unwrap()
                .contains("main -> main")
        );
        assert_eq!(
            Command::new("git")
                .current_dir(remote.path())
                .args(["rev-parse", "refs/heads/main"])
                .output()
                .map(|output| String::from_utf8(output.stdout).unwrap().trim().to_owned())
                .unwrap(),
            Command::new("git")
                .current_dir(directory.path())
                .args(["rev-parse", "HEAD"])
                .output()
                .map(|output| String::from_utf8(output.stdout).unwrap().trim().to_owned())
                .unwrap()
        );
        assert_eq!(
            Command::new("git")
                .current_dir(directory.path())
                .args(["config", "--get", "branch.main.remote"])
                .output()
                .map(|output| String::from_utf8(output.stdout).unwrap().trim().to_owned())
                .unwrap(),
            "origin"
        );
        assert_eq!(
            Command::new("git")
                .current_dir(directory.path())
                .args(["config", "--get", "branch.main.merge"])
                .output()
                .map(|output| String::from_utf8(output.stdout).unwrap().trim().to_owned())
                .unwrap(),
            "refs/heads/main"
        );
    }

    #[test]
    fn redacts_remote_credentials_from_push_output_and_errors() {
        let remote = "https://git-user:test-token@example.invalid/repo.git";
        assert_eq!(
            sanitize_remote_url(remote),
            "https://example.invalid/repo.git"
        );
        assert_eq!(
            sanitize_git_error(&format!("failed to connect to {remote}: rejected")),
            "failed to connect to https://example.invalid/repo.git: rejected"
        );
    }

    #[test]
    fn rejects_non_fast_forward_push_unless_force_is_requested() {
        let local = repository();
        let other = repository();
        fs::write(local.path().join("tracked.txt"), "local\n").unwrap();
        assert!(
            Command::new("git")
                .current_dir(local.path())
                .args(["commit", "-am", "local"])
                .status()
                .unwrap()
                .success()
        );
        fs::write(other.path().join("tracked.txt"), "diverged\n").unwrap();
        assert!(
            Command::new("git")
                .current_dir(other.path())
                .args(["commit", "-am", "diverge"])
                .status()
                .unwrap()
                .success()
        );
        let remote = tempfile::tempdir().unwrap();
        assert!(
            Command::new("git")
                .current_dir(remote.path())
                .args(["init", "--bare"])
                .status()
                .unwrap()
                .success()
        );
        for directory in [&local, &other] {
            assert!(
                Command::new("git")
                    .current_dir(directory.path())
                    .args(["remote", "add", "origin", remote.path().to_str().unwrap(),])
                    .status()
                    .unwrap()
                    .success()
            );
        }
        assert_eq!(
            call(
                "git-push",
                json!({
                    "cwd": local.path(),
                    "refspec": "main:main",
                    "force": false
                })
            )["status"],
            "success"
        );
        assert_eq!(
            call(
                "git-push",
                json!({
                    "cwd": other.path(),
                    "refspec": "main:main",
                    "force": false
                })
            )["status"],
            "error"
        );
        assert_eq!(
            call(
                "git-push",
                json!({
                    "cwd": other.path(),
                    "refspec": "main:main",
                    "force": true
                })
            )["status"],
            "success"
        );
        assert_eq!(
            Command::new("git")
                .current_dir(remote.path())
                .args(["rev-parse", "refs/heads/main"])
                .output()
                .map(|output| String::from_utf8(output.stdout).unwrap().trim().to_owned())
                .unwrap(),
            Command::new("git")
                .current_dir(other.path())
                .args(["rev-parse", "HEAD"])
                .output()
                .map(|output| String::from_utf8(output.stdout).unwrap().trim().to_owned())
                .unwrap()
        );
    }

    #[test]
    fn reads_only_valid_worktree_shell_environment_config() {
        let directory = repository();
        let git_dir = gix::discover(directory.path())
            .unwrap()
            .git_dir()
            .to_owned();
        let config_path = git_dir.join("codex-shell-environment.json");

        assert_eq!(
            call(
                "worktree-shell-environment-config",
                json!({"cwd": directory.path()})
            ),
            json!({"shellEnvironment": null})
        );

        fs::write(
            &config_path,
            r#"{"version":1,"set":{"CODEX_ENV":"ipad","EMPTY":""},"exclude":["TOKEN","SECRET"]}"#,
        )
        .unwrap();
        assert_eq!(
            call(
                "worktree-shell-environment-config",
                json!({"cwd": directory.path()})
            ),
            json!({
                "shellEnvironment": {
                    "version": 1,
                    "set": {"CODEX_ENV": "ipad", "EMPTY": ""},
                    "exclude": ["TOKEN", "SECRET"]
                }
            })
        );

        for invalid in [
            r#"{"version":2,"set":{},"exclude":[]}"#,
            r#"{"version":1,"set":{"COUNT":3},"exclude":[]}"#,
            r#"{"version":1,"set":{},"exclude":[3]}"#,
            r#"{"version":1,"set":{},"exclude":[],"extra":true}"#,
            r#"not json"#,
        ] {
            fs::write(&config_path, invalid).unwrap();
            assert_eq!(
                call(
                    "worktree-shell-environment-config",
                    json!({"cwd": directory.path()})
                ),
                json!({"shellEnvironment": null})
            );
        }

        let outside = tempfile::tempdir().unwrap();
        assert_eq!(
            call(
                "worktree-shell-environment-config",
                json!({"cwd": outside.path()})
            ),
            json!({"shellEnvironment": null})
        );
    }

    #[test]
    fn reads_repository_identity_without_spawning_git() {
        let directory = repository();
        assert_eq!(call("availability", json!({})), json!({"available": true}));
        assert_eq!(
            call("current-branch", json!({"root": directory.path()})),
            json!({"branch": "main"})
        );
        let metadata = call("stable-metadata", json!({"cwd": directory.path()}));
        assert_eq!(
            metadata["root"],
            directory.path().to_string_lossy().as_ref()
        );
        assert_eq!(
            metadata["commonDir"],
            directory.path().join(".git").to_string_lossy().as_ref()
        );
        assert_eq!(
            call(
                "branch-exists",
                json!({"root": directory.path(), "branch": "main"})
            ),
            json!({"exists": true})
        );
    }

    #[test]
    fn creates_and_checks_out_branches_without_spawning_git() {
        let directory = repository();
        let initial_head = gix::discover(directory.path())
            .unwrap()
            .head_id()
            .unwrap()
            .detach();

        assert_eq!(
            call(
                "git-create-branch",
                json!({
                    "cwd": directory.path(),
                    "branch": "feature/ipad",
                    "failIfExists": true,
                    "mode": "head",
                })
            ),
            json!({"status": "success", "branch": "feature/ipad"})
        );
        assert_eq!(
            call(
                "git-checkout-branch",
                json!({
                    "cwd": directory.path(),
                    "branch": "feature/ipad",
                })
            ),
            json!({"status": "success", "branch": "feature/ipad"})
        );
        let repository = gix::discover(directory.path()).unwrap();
        assert_eq!(
            current_branch_name(&repository).unwrap().as_deref(),
            Some("feature/ipad")
        );
        assert_eq!(repository.head_id().unwrap().detach(), initial_head);

        let duplicate = call(
            "git-create-branch",
            json!({
                "cwd": directory.path(),
                "branch": "feature/ipad",
                "failIfExists": true,
            }),
        );
        assert_eq!(duplicate["status"], "error");
        assert_eq!(duplicate["errorType"], "branch_exists");
    }

    #[test]
    fn checkout_preserves_dirty_worktree_and_merge_base_is_real() {
        let directory = repository();
        assert_eq!(
            call(
                "git-create-branch",
                json!({
                    "cwd": directory.path(),
                    "branch": "feature/ipad",
                })
            )["status"],
            "success"
        );
        fs::write(directory.path().join("tracked.txt"), "local edit\n").unwrap();
        let dirty = call(
            "git-checkout-branch",
            json!({
                "cwd": directory.path(),
                "branch": "feature/ipad",
            }),
        );
        assert_eq!(dirty["status"], "error");
        assert_eq!(dirty["errorType"], "dirty_worktree");
        assert_eq!(
            fs::read_to_string(directory.path().join("tracked.txt")).unwrap(),
            "local edit\n"
        );

        fs::write(directory.path().join("tracked.txt"), "one\n").unwrap();
        let head = gix::discover(directory.path())
            .unwrap()
            .head_id()
            .unwrap()
            .to_string();
        assert_eq!(
            call(
                "git-merge-base",
                json!({
                    "gitRoot": directory.path(),
                    "baseBranch": "feature/ipad",
                })
            ),
            json!({"mergeBaseSha": head})
        );
        assert_eq!(
            call(
                "git-merge-base",
                json!({
                    "gitRoot": directory.path(),
                    "baseBranch": "missing",
                })
            ),
            json!({"mergeBaseSha": null})
        );
    }

    #[test]
    fn initializes_repository_and_persists_local_and_worktree_config() {
        let initialized = tempfile::tempdir().unwrap();
        let root = initialized.path().join("new-repository");
        assert_eq!(
            call("git-init-repo", json!({"cwd": root})),
            json!({"success": true})
        );
        let discovered = gix::discover(&root).unwrap();
        assert_eq!(discovered.workdir(), Some(root.as_path()));

        assert_eq!(
            call(
                "set-config-value",
                json!({
                    "root": root,
                    "scope": "local",
                    "key": "codex.ipadMode",
                    "value": "enabled",
                })
            ),
            json!({"success": true})
        );
        assert_eq!(
            call(
                "config-value",
                json!({
                    "root": root,
                    "scope": "local",
                    "key": "codex.ipadMode",
                })
            ),
            json!({"value": "enabled"})
        );
        assert_eq!(
            call(
                "set-config-value",
                json!({
                    "root": root,
                    "scope": "local",
                    "key": "codex.ipadMode",
                    "value": null,
                })
            ),
            json!({"success": true})
        );
        assert_eq!(
            call(
                "config-value",
                json!({
                    "root": root,
                    "scope": "local",
                    "key": "codex.ipadMode",
                })
            ),
            json!({"value": null})
        );

        assert_eq!(
            call(
                "set-config-value",
                json!({
                    "root": root,
                    "scope": "worktree",
                    "key": "codex.owner",
                    "value": "thread-ipad",
                })
            ),
            json!({"success": true})
        );
        let worktree_config =
            fs::read_to_string(discovered.git_dir().join("config.worktree")).unwrap();
        assert!(worktree_config.contains("[codex]"));
        assert!(worktree_config.contains("owner = thread-ipad"));
    }

    #[test]
    fn commits_staged_index_without_external_git() {
        let directory = repository();
        fs::write(directory.path().join("tracked.txt"), "two\n").unwrap();
        assert!(
            Command::new("git")
                .current_dir(directory.path())
                .args(["add", "tracked.txt"])
                .status()
                .unwrap()
                .success()
        );
        let result = call(
            "commit",
            json!({
                "cwd": directory.path(),
                "message": "embedded iPad commit",
                "includeUnstaged": false,
            }),
        );
        assert_eq!(result["status"], "success");
        let sha = result["commitSha"].as_str().unwrap();
        assert_eq!(sha.len(), 40);
        let repository = gix::discover(directory.path()).unwrap();
        assert_eq!(repository.head_id().unwrap().to_string(), sha);
        assert_eq!(
            repository
                .head_commit()
                .unwrap()
                .message_raw()
                .unwrap()
                .to_str()
                .unwrap(),
            "embedded iPad commit"
        );

        let nothing = call(
            "commit",
            json!({
                "cwd": directory.path(),
                "message": "nothing",
                "includeUnstaged": false,
            }),
        );
        assert_eq!(nothing["status"], "error");
        assert_eq!(nothing["errorType"], "nothing-to-commit");
    }

    #[test]
    fn stages_all_worktree_changes_before_embedded_commit() {
        let directory = repository();
        fs::write(directory.path().join(".gitignore"), "ignored.txt\n").unwrap();
        fs::write(directory.path().join("tracked.txt"), "worktree change\n").unwrap();
        fs::write(directory.path().join("added.txt"), "new file\n").unwrap();
        fs::write(directory.path().join("ignored.txt"), "do not commit\n").unwrap();
        let result = call(
            "commit",
            json!({
                "cwd": directory.path(),
                "message": "stage everything on iPad",
                "includeUnstaged": true,
            }),
        );
        assert_eq!(result["status"], "success");
        let show = Command::new("git")
            .current_dir(directory.path())
            .args(["show", "--format=", "--name-only", "HEAD"])
            .output()
            .unwrap();
        assert!(show.status.success());
        let names = String::from_utf8(show.stdout).unwrap();
        assert!(names.lines().any(|line| line == ".gitignore"));
        assert!(names.lines().any(|line| line == "added.txt"));
        assert!(names.lines().any(|line| line == "tracked.txt"));
        assert!(!names.lines().any(|line| line == "ignored.txt"));
        let status = Command::new("git")
            .current_dir(directory.path())
            .args(["status", "--porcelain"])
            .output()
            .unwrap();
        assert!(status.status.success());
        assert!(status.stdout.is_empty());
    }

    #[test]
    fn applies_reverts_and_atomically_rejects_text_patches() {
        let directory = repository();
        let diff = concat!(
            "diff --git a/tracked.txt b/tracked.txt\n",
            "--- a/tracked.txt\n",
            "+++ b/tracked.txt\n",
            "@@ -1 +1 @@\n",
            "-one\n",
            "+two\n",
            "diff --git a/added.txt b/added.txt\n",
            "new file mode 100644\n",
            "--- /dev/null\n",
            "+++ b/added.txt\n",
            "@@ -0,0 +1 @@\n",
            "+added\n",
        );
        let applied = call(
            "apply-patch",
            json!({
                "cwd": directory.path(),
                "diff": diff,
                "atomic": true,
                "target": "unstaged",
            }),
        );
        assert_eq!(applied["status"], "success");
        assert_eq!(applied["appliedPaths"], json!(["tracked.txt", "added.txt"]));
        assert_eq!(
            fs::read_to_string(directory.path().join("tracked.txt")).unwrap(),
            "two\n"
        );
        assert_eq!(
            fs::read_to_string(directory.path().join("added.txt")).unwrap(),
            "added\n"
        );

        let reverted = call(
            "apply-patch",
            json!({
                "cwd": directory.path(),
                "diff": diff,
                "atomic": true,
                "revert": true,
                "target": "unstaged",
            }),
        );
        assert_eq!(reverted["status"], "success");
        assert_eq!(
            fs::read_to_string(directory.path().join("tracked.txt")).unwrap(),
            "one\n"
        );
        assert!(!directory.path().join("added.txt").exists());

        let mismatch = concat!(
            "--- a/tracked.txt\n",
            "+++ b/tracked.txt\n",
            "@@ -1 +1 @@\n",
            "-not-the-current-line\n",
            "+corrupt\n",
        );
        let rejected = call(
            "apply-patch",
            json!({
                "cwd": directory.path(),
                "diff": mismatch,
                "atomic": true,
                "target": "unstaged",
            }),
        );
        assert_eq!(rejected["status"], "error");
        assert!(rejected["appliedPaths"].as_array().unwrap().is_empty());
        assert_eq!(
            fs::read_to_string(directory.path().join("tracked.txt")).unwrap(),
            "one\n"
        );
    }

    #[test]
    fn applies_patches_to_staged_and_combined_targets_without_external_git() {
        let directory = repository();
        let diff = concat!(
            "--- a/tracked.txt\n",
            "+++ b/tracked.txt\n",
            "@@ -1 +1 @@\n",
            "-one\n",
            "+staged\n",
        );
        let staged = call(
            "apply-patch",
            json!({
                "cwd": directory.path(),
                "diff": diff,
                "atomic": true,
                "target": "staged",
            }),
        );
        assert_eq!(staged["status"], "success");
        assert_eq!(staged["appliedPaths"], json!(["tracked.txt"]));
        assert_eq!(
            fs::read_to_string(directory.path().join("tracked.txt")).unwrap(),
            "one\n"
        );
        let staged_contents = Command::new("git")
            .current_dir(directory.path())
            .args(["show", ":tracked.txt"])
            .output()
            .unwrap();
        assert!(staged_contents.status.success());
        assert_eq!(staged_contents.stdout, b"staged\n");

        fs::write(directory.path().join("tracked.txt"), "staged\n").unwrap();
        let combined_diff = concat!(
            "--- a/tracked.txt\n",
            "+++ b/tracked.txt\n",
            "@@ -1 +1 @@\n",
            "-staged\n",
            "+combined\n",
        );
        let combined = call(
            "apply-patch",
            json!({
                "cwd": directory.path(),
                "diff": combined_diff,
                "atomic": true,
                "target": "staged-and-unstaged",
            }),
        );
        assert_eq!(combined["status"], "success");
        assert_eq!(combined["appliedPaths"], json!(["tracked.txt"]));
        assert_eq!(
            fs::read_to_string(directory.path().join("tracked.txt")).unwrap(),
            "combined\n"
        );
        let combined_contents = Command::new("git")
            .current_dir(directory.path())
            .args(["show", ":tracked.txt"])
            .output()
            .unwrap();
        assert!(combined_contents.status.success());
        assert_eq!(combined_contents.stdout, b"combined\n");

        fs::write(directory.path().join("tracked.txt"), "different\n").unwrap();
        let rejected = call(
            "apply-patch",
            json!({
                "cwd": directory.path(),
                "diff": concat!(
                    "--- a/tracked.txt\n",
                    "+++ b/tracked.txt\n",
                    "@@ -1 +1 @@\n",
                    "-combined\n",
                    "+should-not-land\n",
                ),
                "atomic": true,
                "target": "staged-and-unstaged",
            }),
        );
        assert_eq!(rejected["status"], "error");
        assert_eq!(
            fs::read_to_string(directory.path().join("tracked.txt")).unwrap(),
            "different\n"
        );
        let unchanged_index = Command::new("git")
            .current_dir(directory.path())
            .args(["show", ":tracked.txt"])
            .output()
            .unwrap();
        assert!(unchanged_index.status.success());
        assert_eq!(unchanged_index.stdout, b"combined\n");
    }

    #[test]
    fn applies_branch_changes_and_preserves_destination_index() {
        let directory = repository();
        let git = |arguments: &[&str]| {
            let output = Command::new("git")
                .current_dir(directory.path())
                .args(arguments)
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "git {:?}: {}",
                arguments,
                String::from_utf8_lossy(&output.stderr)
            );
            String::from_utf8(output.stdout).unwrap().trim().to_owned()
        };
        fs::write(directory.path().join("other.txt"), "base\n").unwrap();
        git(&["add", "other.txt"]);
        git(&["commit", "-m", "add other"]);
        let destination = git(&["rev-parse", "HEAD"]);
        git(&["switch", "-c", "source"]);
        fs::write(directory.path().join("tracked.txt"), "from source\n").unwrap();
        git(&["add", "tracked.txt"]);
        git(&["commit", "-m", "source change"]);
        let source = git(&["rev-parse", "HEAD"]);
        git(&["switch", "main"]);
        fs::write(directory.path().join("other.txt"), "destination staged\n").unwrap();
        git(&["add", "other.txt"]);

        let result = call(
            "apply-changes",
            json!({
                "sourceHeadRef": source,
                "sourceTreeRef": source,
                "destinationRoot": directory.path(),
                "destinationHeadRef": destination,
            }),
        );
        assert_eq!(result["status"], "success");
        assert_eq!(
            fs::read_to_string(directory.path().join("tracked.txt")).unwrap(),
            "from source\n"
        );
        assert_eq!(git(&["show", ":tracked.txt"]), "one");
        assert_eq!(git(&["show", ":other.txt"]), "destination staged");
    }

    #[test]
    fn three_way_merges_disjoint_edits_and_materializes_overlapping_conflicts() {
        let directory = repository();
        let git = |arguments: &[&str]| {
            let output = Command::new("git")
                .current_dir(directory.path())
                .args(arguments)
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "git {:?}: {}",
                arguments,
                String::from_utf8_lossy(&output.stderr)
            );
            String::from_utf8(output.stdout).unwrap().trim().to_owned()
        };
        for path in ["clean.txt", "conflict.txt"] {
            fs::write(directory.path().join(path), "alpha\nmiddle\nomega\n").unwrap();
        }
        git(&["add", "clean.txt", "conflict.txt"]);
        git(&["commit", "-m", "three way base"]);
        git(&["switch", "-c", "source-three-way"]);
        fs::write(
            directory.path().join("clean.txt"),
            "source-alpha\nmiddle\nomega\n",
        )
        .unwrap();
        fs::write(
            directory.path().join("conflict.txt"),
            "alpha\nsource-middle\nomega\n",
        )
        .unwrap();
        git(&["add", "clean.txt", "conflict.txt"]);
        git(&["commit", "-m", "source edits"]);
        let source = git(&["rev-parse", "HEAD"]);

        git(&["switch", "main"]);
        fs::write(
            directory.path().join("clean.txt"),
            "alpha\nmiddle\ndestination-omega\n",
        )
        .unwrap();
        fs::write(
            directory.path().join("conflict.txt"),
            "alpha\ndestination-middle\nomega\n",
        )
        .unwrap();
        git(&["add", "clean.txt", "conflict.txt"]);
        git(&["commit", "-m", "destination edits"]);
        let destination = git(&["rev-parse", "HEAD"]);

        let result = call(
            "apply-changes",
            json!({
                "sourceHeadRef": source,
                "sourceTreeRef": source,
                "destinationRoot": directory.path(),
                "destinationHeadRef": destination,
            }),
        );
        assert_eq!(result["status"], "partial-success");
        assert_eq!(result["appliedPaths"], json!(["clean.txt"]));
        assert_eq!(result["conflictedPaths"], json!(["conflict.txt"]));
        assert_eq!(
            fs::read_to_string(directory.path().join("clean.txt")).unwrap(),
            "source-alpha\nmiddle\ndestination-omega\n"
        );
        assert_eq!(
            fs::read_to_string(directory.path().join("conflict.txt")).unwrap(),
            concat!(
                "<<<<<<< destination\n",
                "alpha\n",
                "destination-middle\n",
                "omega\n",
                "=======\n",
                "alpha\n",
                "source-middle\n",
                "omega\n",
                ">>>>>>> source\n",
            )
        );
        assert_eq!(
            git(&["show", ":clean.txt"]),
            "alpha\nmiddle\ndestination-omega"
        );
    }

    #[test]
    fn applies_review_stage_unstage_and_revert_with_exact_revisions() {
        let directory = repository();
        fs::write(directory.path().join("tracked.txt"), "two\n").unwrap();
        let summary = call(
            "review-summary",
            json!({
                "cwd": directory.path(),
                "source": "unstaged",
                "paths": ["tracked.txt"],
                "includeUntrackedFiles": true,
            }),
        );
        let file = summary["files"][0].clone();
        let stage = call(
            "apply-review-section-changes",
            json!({
                "action": "stage",
                "cwd": directory.path(),
                "source": "unstaged",
                "files": [file],
            }),
        );
        assert_eq!(stage["status"], "success");
        let staged_contents = Command::new("git")
            .current_dir(directory.path())
            .args(["show", ":tracked.txt"])
            .output()
            .unwrap();
        assert_eq!(staged_contents.stdout, b"two\n");

        let staged_summary = call(
            "review-summary",
            json!({
                "cwd": directory.path(),
                "source": "staged",
                "paths": ["tracked.txt"],
                "includeUntrackedFiles": true,
            }),
        );
        let unstage = call(
            "apply-review-section-changes",
            json!({
                "action": "unstage",
                "cwd": directory.path(),
                "source": "staged",
                "files": [staged_summary["files"][0].clone()],
            }),
        );
        assert_eq!(unstage["status"], "success");
        let unstaged_index = Command::new("git")
            .current_dir(directory.path())
            .args(["show", ":tracked.txt"])
            .output()
            .unwrap();
        assert_eq!(unstaged_index.stdout, b"one\n");
        assert_eq!(
            fs::read_to_string(directory.path().join("tracked.txt")).unwrap(),
            "two\n"
        );

        let refreshed = call(
            "review-summary",
            json!({
                "cwd": directory.path(),
                "source": "unstaged",
                "paths": ["tracked.txt"],
                "includeUntrackedFiles": true,
            }),
        );
        let revert = call(
            "apply-review-section-changes",
            json!({
                "action": "revert",
                "cwd": directory.path(),
                "source": "unstaged",
                "files": [refreshed["files"][0].clone()],
            }),
        );
        assert_eq!(revert["status"], "success");
        assert_eq!(
            fs::read_to_string(directory.path().join("tracked.txt")).unwrap(),
            "one\n"
        );

        fs::write(directory.path().join("tracked.txt"), "three\n").unwrap();
        let stale = call(
            "apply-review-section-changes",
            json!({
                "action": "stage",
                "cwd": directory.path(),
                "source": "unstaged",
                "files": [refreshed["files"][0].clone()],
            }),
        );
        assert_eq!(stale["status"], "error");
        assert_eq!(stale["errorCode"], "stale-or-invalid-selection");
    }

    #[test]
    fn creates_valid_linked_worktree_and_removes_it_with_embedded_core() {
        let directory = repository();
        fs::write(directory.path().join("tracked.txt"), "working tree\n").unwrap();
        fs::write(directory.path().join("untracked.txt"), "copied\n").unwrap();
        let holder = tempfile::tempdir().unwrap();
        let worktree = holder.path().join("linked");
        let created = call(
            "create-worktree",
            json!({
                "cwd": directory.path(),
                "worktreeRoot": worktree,
                "startingState": {
                    "type": "working-tree",
                },
            }),
        );
        assert_eq!(created["setupError"], Value::Null);
        assert_eq!(
            fs::read_to_string(worktree.join("tracked.txt")).unwrap(),
            "working tree\n"
        );
        assert_eq!(
            fs::read_to_string(worktree.join("untracked.txt")).unwrap(),
            "copied\n"
        );
        let recognized = Command::new("git")
            .current_dir(&worktree)
            .args(["rev-parse", "--is-inside-work-tree"])
            .output()
            .unwrap();
        assert!(recognized.status.success());
        assert_eq!(recognized.stdout, b"true\n");
        let listed = Command::new("git")
            .current_dir(directory.path())
            .args(["worktree", "list", "--porcelain"])
            .output()
            .unwrap();
        assert!(listed.status.success());
        assert!(
            String::from_utf8(listed.stdout)
                .unwrap()
                .contains(worktree.to_string_lossy().as_ref())
        );

        fs::write(worktree.join("tracked.txt"), "dirty\n").unwrap();
        assert!(
            request(&json!({
                "method": "delete-worktree",
                "params": {"worktree": worktree, "force": false},
            }))
            .is_err()
        );
        let removed = call(
            "delete-worktree",
            json!({"worktree": worktree, "force": true}),
        );
        assert_eq!(removed["success"], true);
        assert!(!worktree.exists());
        let after = Command::new("git")
            .current_dir(directory.path())
            .args(["worktree", "list", "--porcelain"])
            .output()
            .unwrap();
        assert!(after.status.success());
        assert!(
            !String::from_utf8(after.stdout)
                .unwrap()
                .contains(worktree.to_string_lossy().as_ref())
        );
    }

    #[test]
    fn captures_turn_diffs_and_retains_checkpoints_without_touching_index() {
        let directory = repository();
        fs::write(directory.path().join("tracked.txt"), "staged\n").unwrap();
        let staged = Command::new("git")
            .current_dir(directory.path())
            .args(["add", "tracked.txt"])
            .output()
            .unwrap();
        assert!(staged.status.success());
        fs::write(directory.path().join("tracked.txt"), "turn start\n").unwrap();
        fs::write(directory.path().join("untracked.txt"), "start\n").unwrap();
        let index_before = fs::read(directory.path().join(".git/index")).unwrap();

        let capture = call(
            "turn-diff-capture-start",
            json!({
                "cwd": directory.path(),
                "checkpointKey": "session",
                "turnId": "turn-1",
            }),
        );
        assert!(capture["baseTreeSha"].as_str().is_some());
        assert_eq!(capture["sessionStartDiff"]["type"], "success");
        assert_eq!(
            fs::read(directory.path().join(".git/index")).unwrap(),
            index_before
        );

        fs::write(directory.path().join("tracked.txt"), "turn complete\n").unwrap();
        fs::write(directory.path().join("untracked.txt"), "complete\n").unwrap();
        let completed = call(
            "turn-diff-capture-complete",
            json!({
                "capture": capture,
                "retainCheckpoint": true,
            }),
        );
        assert_eq!(completed["diff"]["type"], "success");
        assert!(
            completed["diff"]["unifiedDiff"]
                .as_str()
                .unwrap()
                .contains("turn complete")
        );
        assert_eq!(
            fs::read(directory.path().join(".git/index")).unwrap(),
            index_before
        );

        let next = call(
            "turn-diff-capture-start",
            json!({
                "cwd": directory.path(),
                "checkpointKey": "session",
                "turnId": "turn-2",
                "baseTurnId": "turn-1",
            }),
        );
        assert_eq!(next["baseTurnHeadTreeSha"], completed["headTreeSha"]);
        assert_eq!(next["sessionStartCommitSha"], Value::Null);
    }

    #[test]
    fn overwrites_linked_checkout_and_creates_synthetic_working_tree_commit() {
        let directory = repository();
        let git = |cwd: &Path, arguments: &[&str]| {
            let output = Command::new("git")
                .current_dir(cwd)
                .args(arguments)
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "git {:?}: {}",
                arguments,
                String::from_utf8_lossy(&output.stderr)
            );
            String::from_utf8(output.stdout).unwrap().trim().to_owned()
        };
        fs::write(directory.path().join("removed.txt"), "remove me\n").unwrap();
        git(directory.path(), &["add", "removed.txt"]);
        git(directory.path(), &["commit", "-m", "add removable"]);
        let holder = tempfile::tempdir().unwrap();
        let target = holder.path().join("target");
        git(
            directory.path(),
            &[
                "worktree",
                "add",
                "-b",
                "target",
                target.to_str().unwrap(),
                "HEAD",
            ],
        );

        fs::write(directory.path().join("tracked.txt"), "source head\n").unwrap();
        fs::write(directory.path().join("added.txt"), "added\n").unwrap();
        fs::remove_file(directory.path().join("removed.txt")).unwrap();
        git(directory.path(), &["add", "-A"]);
        git(directory.path(), &["commit", "-m", "source state"]);
        let head = git(directory.path(), &["rev-parse", "HEAD"]);
        let overwritten = call(
            "overwrite-repo",
            json!({
                "gitRoot": directory.path(),
                "targetRoot": target,
                "branchName": "main",
                "headCommitSha": head,
                "targetCurrentBranch": "target",
            }),
        );
        assert_eq!(overwritten["status"], "success");
        assert_eq!(git(&target, &["rev-parse", "HEAD"]), head);
        assert_eq!(
            fs::read_to_string(target.join("tracked.txt")).unwrap(),
            "source head\n"
        );
        assert_eq!(
            fs::read_to_string(target.join("added.txt")).unwrap(),
            "added\n"
        );
        assert!(!target.join("removed.txt").exists());
        assert!(git(&target, &["status", "--porcelain"]).is_empty());

        let original = head;
        fs::write(directory.path().join("tracked.txt"), "synthetic\n").unwrap();
        fs::write(directory.path().join("untracked.txt"), "included\n").unwrap();
        let snapshot = call(
            "turn-diff-capture-start",
            json!({
                "cwd": directory.path(),
                "checkpointKey": "overwrite",
                "turnId": "synthetic",
            }),
        );
        let synthetic = call(
            "overwrite-repo",
            json!({
                "gitRoot": directory.path(),
                "branchName": "main",
                "headCommitSha": original,
                "treeSha": snapshot["baseTreeSha"],
            }),
        );
        assert_eq!(synthetic["status"], "success");
        assert_ne!(git(directory.path(), &["rev-parse", "HEAD"]), original);
        assert_eq!(git(directory.path(), &["rev-parse", "HEAD^"]), original);
        assert_eq!(
            fs::read_to_string(directory.path().join("tracked.txt")).unwrap(),
            "synthetic\n"
        );
        assert_eq!(
            fs::read_to_string(directory.path().join("untracked.txt")).unwrap(),
            "included\n"
        );
        assert!(git(directory.path(), &["status", "--porcelain"]).is_empty());
    }

    #[test]
    fn moves_thread_changes_from_linked_worktree_to_local_without_external_git() {
        let directory = repository();
        let git = |cwd: &Path, arguments: &[&str]| {
            let output = Command::new("git")
                .current_dir(cwd)
                .args(arguments)
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "git {:?}: {}",
                arguments,
                String::from_utf8_lossy(&output.stderr)
            );
            String::from_utf8(output.stdout).unwrap().trim().to_owned()
        };
        let holder = tempfile::tempdir().unwrap();
        let source = holder.path().join("source");
        git(
            directory.path(),
            &[
                "worktree",
                "add",
                "-b",
                "feature/ipad",
                source.to_str().unwrap(),
                "HEAD",
            ],
        );
        fs::write(source.join("tracked.txt"), "moved\n").unwrap();
        fs::write(source.join("untracked.txt"), "also moved\n").unwrap();

        let moved = call(
            "move-thread-to-local",
            json!({
                "sourceWorktreeCwd": source,
                "sourceWorktreeRoot": source,
                "localGitRoot": directory.path(),
                "sourceBranch": "feature/ipad",
            }),
        );
        assert_eq!(moved["status"], "success");
        assert_eq!(
            fs::read_to_string(directory.path().join("tracked.txt")).unwrap(),
            "moved\n"
        );
        assert_eq!(
            fs::read_to_string(directory.path().join("untracked.txt")).unwrap(),
            "also moved\n"
        );
        assert_eq!(
            git(directory.path(), &["branch", "--show-current"]),
            "feature/ipad"
        );
        assert!(!git(directory.path(), &["status", "--porcelain"]).is_empty());
        assert!(git(&source, &["branch", "--show-current"]).is_empty());
        assert!(git(&source, &["status", "--porcelain"]).is_empty());
    }

    #[test]
    fn moves_thread_changes_from_local_to_linked_worktree_without_external_git() {
        let directory = repository();
        let git = |cwd: &Path, arguments: &[&str]| {
            let output = Command::new("git")
                .current_dir(cwd)
                .args(arguments)
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "git {:?}: {}",
                arguments,
                String::from_utf8_lossy(&output.stderr)
            );
            String::from_utf8(output.stdout).unwrap().trim().to_owned()
        };
        git(directory.path(), &["checkout", "-b", "feature/ipad"]);
        let holder = tempfile::tempdir().unwrap();
        let target = holder.path().join("target");
        git(
            directory.path(),
            &[
                "worktree",
                "add",
                "--detach",
                target.to_str().unwrap(),
                "HEAD",
            ],
        );
        fs::write(directory.path().join("tracked.txt"), "moved\n").unwrap();
        fs::write(directory.path().join("untracked.txt"), "also moved\n").unwrap();

        let moved = call(
            "move-thread-to-worktree",
            json!({
                "localCwd": directory.path(),
                "sourceBranch": "feature/ipad",
                "defaultBranch": "main",
                "localCheckoutBranch": "main",
                "worktreeCheckoutBranch": "feature/ipad",
                "worktreeGitRoot": target,
                "worktreeWorkspaceRoot": target,
                "stashTargetWorktree": false,
                "createdWorktree": false,
            }),
        );
        assert_eq!(moved["status"], "success");
        assert_eq!(git(directory.path(), &["branch", "--show-current"]), "main");
        assert!(git(directory.path(), &["status", "--porcelain"]).is_empty());
        assert_eq!(git(&target, &["branch", "--show-current"]), "feature/ipad");
        assert_eq!(
            fs::read_to_string(target.join("tracked.txt")).unwrap(),
            "moved\n"
        );
        assert_eq!(
            fs::read_to_string(target.join("untracked.txt")).unwrap(),
            "also moved\n"
        );
        assert!(!git(&target, &["status", "--porcelain"]).is_empty());
        assert_eq!(
            moved["_progress"][4],
            json!({"step": "apply-changes-to-worktree", "status": "completed"})
        );
    }

    #[test]
    fn transfers_host_handoff_objects_rollout_and_worktree_without_external_git() {
        let source = repository();
        let git = |cwd: &Path, arguments: &[&str]| {
            let output = Command::new("git")
                .current_dir(cwd)
                .args(arguments)
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "git {:?}: {}",
                arguments,
                String::from_utf8_lossy(&output.stderr)
            );
            String::from_utf8(output.stdout).unwrap().trim().to_owned()
        };
        let holder = tempfile::tempdir().unwrap();
        let destination = holder.path().join("destination");
        git(
            holder.path(),
            &[
                "clone",
                source.path().to_str().unwrap(),
                destination.to_str().unwrap(),
            ],
        );
        git(source.path(), &["checkout", "-b", "feature/host"]);
        fs::write(source.path().join("tracked.txt"), "committed feature\n").unwrap();
        git(source.path(), &["add", "tracked.txt"]);
        git(source.path(), &["commit", "-m", "feature commit"]);
        fs::write(source.path().join("tracked.txt"), "dirty feature\n").unwrap();
        fs::write(source.path().join("host.txt"), "untracked host\n").unwrap();
        let rollout = holder.path().join("source-rollout.jsonl");
        fs::write(&rollout, "{\"type\":\"session_meta\"}\n").unwrap();
        let codex_home = holder.path().join("codex-home");

        let moved = call(
            "move-thread-to-host-worktree",
            json!({
                "sourceCwd": source.path(),
                "sourceBranch": "feature/host",
                "sourceRolloutPath": rollout,
                "destinationWorkspaceRoot": destination,
                "destinationWorktreeGitRoot": null,
                "destinationWorktreeWorkspaceRoot": null,
                "stashDestinationWorktree": false,
                "codexHome": codex_home,
            }),
        );
        assert_eq!(moved["status"], "success");
        let target = PathBuf::from(moved["worktreeWorkspaceRoot"].as_str().unwrap());
        assert_eq!(git(&target, &["branch", "--show-current"]), "feature/host");
        assert_eq!(
            fs::read_to_string(target.join("tracked.txt")).unwrap(),
            "dirty feature\n"
        );
        assert_eq!(
            fs::read_to_string(target.join("host.txt")).unwrap(),
            "untracked host\n"
        );
        let copied_rollout = PathBuf::from(moved["rolloutPath"].as_str().unwrap());
        assert_eq!(
            fs::read_to_string(&copied_rollout).unwrap(),
            "{\"type\":\"session_meta\"}\n"
        );
        assert_eq!(
            call(
                "cleanup-host-handoff-transfer",
                json!({
                    "rolloutPath": copied_rollout,
                    "codexHome": codex_home,
                }),
            ),
            json!({"success": true})
        );
        assert!(!copied_rollout.parent().unwrap().exists());
    }

    #[test]
    fn emits_and_applies_binary_tree_patch_without_external_git() {
        let directory = repository();
        let git = |arguments: &[&str]| {
            let output = Command::new("git")
                .current_dir(directory.path())
                .args(arguments)
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "git {:?}: {}",
                arguments,
                String::from_utf8_lossy(&output.stderr)
            );
        };
        let path = directory.path().join("binary.dat");
        fs::write(&path, b"old\0binary\xff").unwrap();
        git(&["add", "binary.dat"]);
        git(&["commit", "-m", "binary base"]);
        let repository = discover(directory.path()).unwrap();
        let base = repository
            .head_commit()
            .unwrap()
            .tree_id()
            .unwrap()
            .detach();
        fs::write(&path, b"new\0binary\xfe\xfd").unwrap();
        let snapshot = working_tree(&repository, false).unwrap();
        let diff = git_diff::tree_diff(directory.path(), &base.to_string(), &snapshot.to_string())
            .unwrap();
        assert!(diff.contains("GIT binary patch"));
        restore_tree_to_worktree(&repository, base, Some(snapshot)).unwrap();
        let mut params = serde_json::Map::new();
        params.insert(
            "cwd".to_owned(),
            Value::String(directory.path().to_string_lossy().into_owned()),
        );
        params.insert("diff".to_owned(), Value::String(diff));
        params.insert("atomic".to_owned(), Value::Bool(true));
        params.insert("target".to_owned(), Value::String("unstaged".to_owned()));
        assert_eq!(apply_patch(&params).unwrap()["status"], "success");
        assert_eq!(fs::read(path).unwrap(), b"new\0binary\xfe\xfd");
    }

    #[test]
    fn emits_applies_stages_and_reverts_exact_renames_without_external_git() {
        let directory = repository();
        let git = |arguments: &[&str]| {
            let output = Command::new("git")
                .current_dir(directory.path())
                .args(arguments)
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "git {:?}: {}",
                arguments,
                String::from_utf8_lossy(&output.stderr)
            );
        };
        let old_path = directory.path().join("tracked.txt");
        let new_path = directory.path().join("renamed.txt");
        let repository = discover(directory.path()).unwrap();
        let base = repository
            .head_commit()
            .unwrap()
            .tree_id()
            .unwrap()
            .detach();
        fs::rename(&old_path, &new_path).unwrap();
        let renamed = working_tree(&repository, false).unwrap();
        let diff =
            git_diff::tree_diff(directory.path(), &base.to_string(), &renamed.to_string()).unwrap();
        assert!(diff.contains("rename from tracked.txt"));
        assert!(diff.contains("rename to renamed.txt"));

        restore_tree_to_worktree(&repository, base, Some(renamed)).unwrap();
        let mut params = serde_json::Map::new();
        params.insert(
            "cwd".to_owned(),
            Value::String(directory.path().to_string_lossy().into_owned()),
        );
        params.insert("diff".to_owned(), Value::String(diff.clone()));
        params.insert("atomic".to_owned(), Value::Bool(true));
        params.insert("target".to_owned(), Value::String("unstaged".to_owned()));
        assert_eq!(apply_patch(&params).unwrap()["status"], "success");
        assert!(!old_path.exists());
        assert_eq!(fs::read_to_string(&new_path).unwrap(), "one\n");

        params.insert("revert".to_owned(), Value::Bool(true));
        assert_eq!(apply_patch(&params).unwrap()["status"], "success");
        assert_eq!(fs::read_to_string(&old_path).unwrap(), "one\n");
        assert!(!new_path.exists());

        params.remove("revert");
        params.insert("target".to_owned(), Value::String("staged".to_owned()));
        assert_eq!(apply_patch(&params).unwrap()["status"], "success");
        assert_eq!(git(&["show", ":renamed.txt"]), ());
        let missing_old = Command::new("git")
            .current_dir(directory.path())
            .args(["show", ":tracked.txt"])
            .output()
            .unwrap();
        assert!(!missing_old.status.success());
    }

    #[test]
    fn reports_real_index_worktree_and_untracked_counts() {
        let directory = repository();
        fs::write(directory.path().join("tracked.txt"), "two\n").unwrap();
        fs::write(directory.path().join("untracked.txt"), "new\n").unwrap();
        assert_eq!(
            call(
                "status-summary",
                json!({"cwd": directory.path(), "includeUntrackedFiles": true})
            ),
            json!({
                "type": "success",
                "stagedCount": 0,
                "unstagedCount": 1,
                "untrackedCount": 1
            })
        );
    }

    #[test]
    fn reads_origin_index_and_submodules_from_repository_storage() {
        let directory = repository();
        assert!(
            Command::new("git")
                .current_dir(directory.path())
                .args([
                    "remote",
                    "add",
                    "origin",
                    "https://example.invalid/org/repo.git"
                ])
                .status()
                .unwrap()
                .success()
        );
        fs::write(
            directory.path().join(".gitmodules"),
            "[submodule \"Core\"]\n\tpath = Vendor/Core\n\turl = ../Core.git\n",
        )
        .unwrap();
        let origins = call("git-origins", json!({"dirs": [directory.path()]}));
        assert_eq!(
            origins["origins"][0]["originUrl"],
            "https://example.invalid/org/repo.git"
        );
        assert_eq!(
            call("submodule-paths", json!({"root": directory.path()})),
            json!({"paths": ["Vendor/Core"]})
        );
        assert!(
            call("index-info", json!({"cwd": directory.path()}))["lastModified"]
                .as_f64()
                .unwrap()
                > 0.0
        );
    }

    #[test]
    fn lists_searches_and_counts_branches_without_git_processes() {
        let directory = repository();
        assert!(
            Command::new("git")
                .current_dir(directory.path())
                .args(["branch", "feature/ipad"])
                .status()
                .unwrap()
                .success()
        );
        assert_eq!(
            call(
                "search-branches",
                json!({
                    "root": directory.path(),
                    "query": "ipad",
                    "limit": 20,
                    "preserveRemoteRefs": false
                })
            ),
            json!({"branches": ["feature/ipad"], "remoteBranchRefs": []})
        );
        let recent = call(
            "recent-branches",
            json!({"root": directory.path(), "limit": 10}),
        );
        assert!(
            recent["branches"]
                .as_array()
                .unwrap()
                .iter()
                .any(|value| value == "main")
        );
        assert_eq!(
            call("branch-ahead-count", json!({"root": directory.path()})),
            json!({"commitsAhead": 0})
        );
    }

    #[test]
    fn emits_staged_and_uncommitted_diffs_and_reads_blob_objects() {
        let directory = repository();
        fs::write(directory.path().join("tracked.txt"), "two\n").unwrap();
        assert!(
            Command::new("git")
                .current_dir(directory.path())
                .args(["add", "tracked.txt"])
                .status()
                .unwrap()
                .success()
        );
        let staged = call(
            "commit-message-diff",
            json!({"cwd": directory.path(), "includeUnstaged": false}),
        );
        assert_eq!(staged["type"], "success");
        assert!(staged["unifiedDiff"].as_str().unwrap().contains("-one"));
        assert!(staged["unifiedDiff"].as_str().unwrap().contains("+two"));

        let oid = Command::new("git")
            .current_dir(directory.path())
            .args(["rev-parse", "HEAD:tracked.txt"])
            .output()
            .unwrap();
        let oid = String::from_utf8(oid.stdout).unwrap().trim().to_owned();
        assert_eq!(
            call(
                "cat-file",
                json!({
                    "cwd": directory.path(),
                    "maxObjectBytes": 1024,
                    "requests": [{"oid": oid}]
                })
            ),
            json!([{"type": "success", "lines": ["one"]}])
        );
        let review = call(
            "review-diff",
            json!({
                "cwd": directory.path(),
                "source": "staged",
                "files": [{"path": "tracked.txt"}]
            }),
        );
        assert_eq!(review["type"], "success");
        assert!(
            review["diffs"]["tracked.txt"]["diff"]
                .as_str()
                .unwrap()
                .contains("+two")
        );
    }

    #[test]
    fn searches_review_hunks_and_reports_branch_diff_stats() {
        let directory = repository();
        assert!(
            Command::new("git")
                .current_dir(directory.path())
                .args(["checkout", "-b", "feature/ipad"])
                .status()
                .unwrap()
                .success()
        );
        fs::write(
            directory.path().join("tracked.txt"),
            "Codex search match\nsecond Codex match\n",
        )
        .unwrap();

        let search = call(
            "review-search",
            json!({
                "cwd": directory.path(),
                "source": "uncommitted",
                "query": "codex"
            }),
        );
        assert_eq!(search["type"], "success");
        assert_eq!(search["totalMatches"], 2);
        assert_eq!(search["isCapped"], false);
        assert_eq!(search["matches"][0]["path"], "tracked.txt");
        assert_eq!(search["matches"][0]["snippet"]["match"], "Codex");

        assert_eq!(
            call(
                "branch-diff-stats",
                json!({"cwd": directory.path(), "baseBranch": "main"})
            ),
            json!({"additions": 2, "deletions": 1, "fileCount": 1})
        );

        fs::write(directory.path().join("untracked.txt"), "new file\n").unwrap();
        let summary = call(
            "review-summary",
            json!({
                "cwd": directory.path(),
                "source": "uncommitted",
                "includeUntrackedFiles": true
            }),
        );
        assert_eq!(summary["type"], "success");
        assert_eq!(summary["stageCounts"]["unstagedFileCount"], 1);
        assert_eq!(summary["stageCounts"]["untrackedFileCount"], 1);
        assert_eq!(summary["files"][0]["path"], "tracked.txt");
        assert_eq!(summary["files"][0]["additions"], 2);
        assert_eq!(summary["files"][0]["deletions"], 1);
        assert!(
            summary["files"]
                .as_array()
                .unwrap()
                .iter()
                .any(|file| file["changeKind"] == "untracked")
        );

        let blame = call(
            "blame-file",
            json!({"cwd": directory.path(), "path": "tracked.txt"}),
        );
        assert_eq!(blame["type"], "success");
        assert_eq!(blame["lines"][0]["author"], "Codex");
        assert_eq!(blame["lines"][0]["lineNumber"], 1);
        assert_eq!(blame["lines"][0]["summary"], "initial");
    }

    #[test]
    fn reads_synced_branch_and_managed_snapshot_without_git_processes() {
        let directory = repository();
        fs::write(
            directory.path().join(".git/codex-synced-branch.json"),
            r#"{"branch":"refs/heads/codex/ipad","lastSyncedTreeRef":"tree123"}"#,
        )
        .unwrap();
        assert!(
            Command::new("git")
                .current_dir(directory.path())
                .args(["branch", "codex/ipad"])
                .status()
                .unwrap()
                .success()
        );
        assert_eq!(
            call("synced-branch", json!({"cwd": directory.path()})),
            json!({
                "branch": "codex/ipad",
                "base": "tree123",
                "hasConflicts": false,
            })
        );

        let missing = directory.path().join("../missing-ipad-worktree");
        let (worktree_id, snapshot_ref) = snapshot_identity(&missing);
        let head = Command::new("git")
            .current_dir(directory.path())
            .args(["rev-parse", "HEAD"])
            .output()
            .unwrap();
        let head = String::from_utf8(head.stdout).unwrap().trim().to_owned();
        assert!(
            Command::new("git")
                .current_dir(directory.path())
                .args(["update-ref", &snapshot_ref, &head])
                .status()
                .unwrap()
                .success()
        );
        let snapshot = call(
            "worktree-snapshot-ref",
            json!({
                "candidateRoots": [directory.path()],
                "worktreePath": missing,
            }),
        );
        assert_eq!(snapshot["exists"], true);
        assert_eq!(snapshot["worktreeId"], worktree_id);
        assert_eq!(snapshot["commitSha"], head);
        assert_eq!(
            call(
                "managed-worktree-state",
                json!({
                    "candidateRoots": [directory.path()],
                    "cwd": missing,
                    "worktreePath": missing,
                })
            )["kind"],
            "restorable"
        );
        let state = call("synced-branch-state", json!({"cwd": directory.path()}));
        assert_eq!(state["branch"], "refs/heads/codex/ipad");
        assert_eq!(state["localCommitsAhead"], 0);
        assert_eq!(state["worktreeCommitsAhead"], 0);
        assert_eq!(state["branchSnapshot"]["checkedOut"], false);
        assert_eq!(
            state["worktreeSnapshot"]["root"],
            directory.path().to_string_lossy().as_ref()
        );
        let listed = call("list-worktrees", json!({"cwd": directory.path()}));
        assert_eq!(listed["worktrees"].as_array().unwrap().len(), 1);
        assert_eq!(listed["worktrees"][0]["headRef"]["type"], "branch");
        assert_eq!(listed["worktrees"][0]["headRef"]["string"], "main");

        let codex_root = directory.path().join("codex-worktrees/project/thread");
        fs::create_dir_all(codex_root.parent().unwrap()).unwrap();
        assert!(
            Command::new("git")
                .current_dir(directory.path())
                .args(["worktree", "add", "--detach", codex_root.to_str().unwrap()])
                .status()
                .unwrap()
                .success()
        );
        let codex = call(
            "codex-worktrees",
            json!({"worktreesRoot": directory.path().join("codex-worktrees")}),
        );
        assert_eq!(codex["worktrees"].as_array().unwrap().len(), 1);
        assert_eq!(
            codex["worktrees"][0]["dir"],
            codex_root.to_string_lossy().as_ref()
        );
        assert_eq!(
            call(
                "set-worktree-owner-thread",
                json!({
                    "worktree": codex_root,
                    "conversationId": "thread-ipad",
                })
            ),
            json!({"success": true})
        );
        let resolved = call(
            "resolve-worktree-for-thread",
            json!({
                "cwd": directory.path(),
                "conversationId": "thread-ipad",
            }),
        );
        assert_eq!(
            resolved["worktreeGitRoot"],
            codex_root
                .canonicalize()
                .unwrap()
                .to_string_lossy()
                .as_ref()
        );
        assert_eq!(resolved["hasUncommittedChanges"], false);
    }
}
