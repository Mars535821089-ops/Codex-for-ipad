use crate::CoreError;
use flate2::{Compression, write::ZlibEncoder};
use gix::bstr::{BStr, BString, ByteSlice};
use gix::diff::blob::{
    Algorithm, UnifiedDiff,
    intern::InternedInput,
    sources::byte_lines_with_terminator,
    unified_diff::{ConsumeHunk, ContextSize, DiffLineKind, HunkHeader},
};
use gix::hash::ObjectId;
use gix::index::entry::{Flags, Mode, Stage};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::fmt;
use std::fs;
use std::io::{Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::PermissionsExt;
use std::path::{Component, Path, PathBuf};

const MAX_COMMITS: usize = 100_000;
const MAX_FILES: usize = 100_000;
const MAX_FILE_BYTES: usize = 64 * 1024 * 1024;
const MAX_TOTAL_BYTES: usize = 256 * 1024 * 1024;
const MAX_DIFF_BYTES: usize = 64 * 1024 * 1024;
const CONTEXT_LINES: u32 = 3;

#[derive(Debug)]
pub(super) enum GitDiffError {
    NotRepository,
    BareRepository,
    UnbornHead,
    NoRemoteBase,
    NonUtf8Reference,
    UnsupportedHash,
    UnmergedIndex {
        path: BString,
    },
    SparseIndex {
        path: Option<BString>,
    },
    Gitlink {
        path: BString,
    },
    IntentToAdd {
        path: BString,
    },
    UnsupportedFileType {
        path: BString,
    },
    UnsupportedAttributes {
        path: BString,
    },
    UnsupportedConfiguration {
        key: &'static str,
    },
    LeadingDirectorySymlink {
        path: BString,
    },
    NestedRepository {
        path: BString,
    },
    NonUtf8Content {
        path: BString,
    },
    BudgetExceeded(&'static str),
    Io {
        path: PathBuf,
        source: std::io::Error,
    },
    Gix(String),
}

impl fmt::Display for GitDiffError {
    fn fmt(&self, output: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotRepository => output.write_str("repository discovery failed"),
            Self::BareRepository => output.write_str("repository has no worktree"),
            Self::UnbornHead => output.write_str("repository HEAD has no commit"),
            Self::NoRemoteBase => output.write_str("no remote baseline was found"),
            Self::NonUtf8Reference => output.write_str("reference name is not UTF-8"),
            Self::UnsupportedHash => output.write_str("repository object hash is not SHA-1"),
            Self::UnmergedIndex { path } => write!(output, "unmerged index entry at {path:?}"),
            Self::SparseIndex { path: Some(path) } => {
                write!(output, "sparse index entry at {path:?}")
            }
            Self::SparseIndex { path: None } => output.write_str("sparse index"),
            Self::Gitlink { path } => write!(output, "gitlink entry at {path:?}"),
            Self::IntentToAdd { path } => write!(output, "intent-to-add entry at {path:?}"),
            Self::UnsupportedFileType { path } => {
                write!(output, "special worktree object at {path:?}")
            }
            Self::UnsupportedAttributes { path } => {
                write!(output, "content-transforming attributes at {path:?}")
            }
            Self::UnsupportedConfiguration { key } => {
                write!(output, "unsupported Git configuration: {key}")
            }
            Self::LeadingDirectorySymlink { path } => {
                write!(
                    output,
                    "tracked path crosses a directory symlink at {path:?}"
                )
            }
            Self::NestedRepository { path } => {
                write!(output, "nested repository at {path:?}")
            }
            Self::NonUtf8Content { path } => write!(output, "non-UTF-8 text at {path:?}"),
            Self::BudgetExceeded(name) => write!(output, "{name} budget exceeded"),
            Self::Io { path, source } => write!(output, "{}: {source}", path.display()),
            Self::Gix(message) => output.write_str(message),
        }
    }
}

impl std::error::Error for GitDiffError {}

fn gix_error(error: impl fmt::Display) -> GitDiffError {
    GitDiffError::Gix(error.to_string())
}

fn io_error(path: impl Into<PathBuf>) -> impl FnOnce(std::io::Error) -> GitDiffError {
    let path = path.into();
    move |source| GitDiffError::Io { path, source }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct GitDiffParams {
    cwd: String,
}

#[derive(Debug, Serialize)]
struct GitDiffResponse {
    sha: String,
    diff: String,
}

pub(super) struct GitStatusCounts {
    pub staged: usize,
    pub unstaged: usize,
    pub untracked: usize,
}

pub(super) fn unified_diff(
    cwd: &Path,
    source: &str,
    commit_sha: Option<&str>,
    base_branch: Option<&str>,
) -> Result<String, GitDiffError> {
    let (before, after) = comparison_snapshots(cwd, source, commit_sha, base_branch)?;
    encode_snapshot_diff(&before, &after)
}

pub(super) fn file_diffs(
    cwd: &Path,
    source: &str,
    commit_sha: Option<&str>,
    base_branch: Option<&str>,
    paths: &[(String, Option<String>)],
) -> Result<BTreeMap<String, String>, GitDiffError> {
    let (before, after) = comparison_snapshots(cwd, source, commit_sha, base_branch)?;
    let mut result = BTreeMap::new();
    for (path, previous_path) in paths {
        let selected = [Some(path.as_str()), previous_path.as_deref()]
            .into_iter()
            .flatten()
            .map(BString::from)
            .collect::<BTreeSet<_>>();
        let filtered_before = before
            .iter()
            .filter(|(path, _)| selected.contains(*path))
            .map(|(path, entry)| (path.clone(), entry.clone()))
            .collect();
        let filtered_after = after
            .iter()
            .filter(|(path, _)| selected.contains(*path))
            .map(|(path, entry)| (path.clone(), entry.clone()))
            .collect();
        result.insert(
            path.clone(),
            encode_snapshot_diff(&filtered_before, &filtered_after)?,
        );
    }
    Ok(result)
}

pub(super) fn merge_base_diff(
    cwd: &Path,
    source_head_ref: &str,
    source_tree_ref: &str,
    destination_head_ref: &str,
) -> Result<String, GitDiffError> {
    let repository = gix::discover(cwd).map_err(|_| GitDiffError::NotRepository)?;
    let source_head = repository
        .rev_parse_single(source_head_ref)
        .map_err(gix_error)?
        .detach();
    let destination_head = repository
        .rev_parse_single(destination_head_ref)
        .map_err(gix_error)?
        .detach();
    let source_tree = repository
        .rev_parse_single(source_tree_ref)
        .map_err(gix_error)?
        .detach();
    let base = merge_base(&repository, source_head, destination_head)?;
    let mut budget = ReadBudget::default();
    let before = base_snapshot(&repository, base, &mut budget)?;
    let object = repository.find_object(source_tree).map_err(gix_error)?;
    let tree = match object.kind {
        gix::object::Kind::Tree => object.try_into_tree().map_err(gix_error)?,
        gix::object::Kind::Commit => object
            .try_into_commit()
            .map_err(gix_error)?
            .tree()
            .map_err(gix_error)?,
        _ => return Err(GitDiffError::NoRemoteBase),
    };
    let flattened = repository
        .index_from_tree(&tree.id().detach())
        .map_err(gix_error)?;
    let after = snapshot_index(&repository, &flattened, &mut budget)?;
    encode_snapshot_diff(&before, &after)
}

#[derive(Clone, Debug)]
pub(super) struct MergeFileMaterial {
    pub(super) base: Option<Vec<u8>>,
    pub(super) theirs: Option<Vec<u8>>,
}

pub(super) fn merge_base_material(
    cwd: &Path,
    source_head_ref: &str,
    source_tree_ref: &str,
    destination_head_ref: &str,
) -> Result<BTreeMap<String, MergeFileMaterial>, GitDiffError> {
    let repository = gix::discover(cwd).map_err(|_| GitDiffError::NotRepository)?;
    let source_head = repository
        .rev_parse_single(source_head_ref)
        .map_err(gix_error)?
        .detach();
    let destination_head = repository
        .rev_parse_single(destination_head_ref)
        .map_err(gix_error)?
        .detach();
    let source_tree = repository
        .rev_parse_single(source_tree_ref)
        .map_err(gix_error)?
        .detach();
    let base = merge_base(&repository, source_head, destination_head)?;
    let mut budget = ReadBudget::default();
    let before = base_snapshot(&repository, base, &mut budget)?;
    let object = repository.find_object(source_tree).map_err(gix_error)?;
    let tree = match object.kind {
        gix::object::Kind::Tree => object.try_into_tree().map_err(gix_error)?,
        gix::object::Kind::Commit => object
            .try_into_commit()
            .map_err(gix_error)?
            .tree()
            .map_err(gix_error)?,
        _ => return Err(GitDiffError::NoRemoteBase),
    };
    let flattened = repository
        .index_from_tree(&tree.id().detach())
        .map_err(gix_error)?;
    let after = snapshot_index(&repository, &flattened, &mut budget)?;
    let mut material = BTreeMap::new();
    for path in before.keys().chain(after.keys()).collect::<BTreeSet<_>>() {
        if before.get(path) == after.get(path) {
            continue;
        }
        let path_text = std::str::from_utf8(path.as_bytes())
            .map_err(|_| GitDiffError::NonUtf8Content { path: path.clone() })?;
        material.insert(
            path_text.to_owned(),
            MergeFileMaterial {
                base: before.get(path).map(|entry| entry.data.clone()),
                theirs: after.get(path).map(|entry| entry.data.clone()),
            },
        );
    }
    Ok(material)
}

pub(super) fn tree_diff(cwd: &Path, base: &str, head: &str) -> Result<String, GitDiffError> {
    let repository = gix::discover(cwd).map_err(|_| GitDiffError::NotRepository)?;
    let mut budget = ReadBudget::default();
    let snapshot = |reference: &str, budget: &mut ReadBudget| {
        let id = repository
            .rev_parse_single(reference)
            .map_err(gix_error)?
            .detach();
        let object = repository.find_object(id).map_err(gix_error)?;
        let tree = match object.kind {
            gix::object::Kind::Tree => object.try_into_tree().map_err(gix_error)?,
            gix::object::Kind::Commit => object
                .try_into_commit()
                .map_err(gix_error)?
                .tree()
                .map_err(gix_error)?,
            _ => return Err(GitDiffError::NoRemoteBase),
        };
        let index = repository
            .index_from_tree(&tree.id().detach())
            .map_err(gix_error)?;
        snapshot_index(&repository, &index, budget)
    };
    let before = snapshot(base, &mut budget)?;
    let after = snapshot(head, &mut budget)?;
    encode_snapshot_diff(&before, &after)
}

fn comparison_snapshots(
    cwd: &Path,
    source: &str,
    commit_sha: Option<&str>,
    base_branch: Option<&str>,
) -> Result<(BTreeMap<BString, FileEntry>, BTreeMap<BString, FileEntry>), GitDiffError> {
    let repository = gix::discover(cwd).map_err(|_| GitDiffError::NotRepository)?;
    let workdir = repository
        .workdir()
        .ok_or(GitDiffError::BareRepository)?
        .to_owned();
    let index = repository.index_or_empty().map_err(gix_error)?;
    validate_index(&index)?;
    let mut budget = ReadBudget::default();
    let head = repository.head_id().ok().map(|id| id.detach());
    let head_snapshot = match head {
        Some(head) => base_snapshot(&repository, head, &mut budget)?,
        None => BTreeMap::new(),
    };
    let index_snapshot = snapshot_index(&repository, &index, &mut budget)?;
    let tracked_snapshot = tracked_worktree_snapshot(&repository, &workdir, &index, &mut budget)?;
    let snapshots = match source {
        "staged" => (head_snapshot, index_snapshot),
        "unstaged" => (index_snapshot, tracked_snapshot),
        "uncommitted" => (head_snapshot, tracked_snapshot),
        "commit" => {
            let sha = commit_sha.ok_or(GitDiffError::UnbornHead)?;
            let oid = ObjectId::from_hex(sha.as_bytes()).map_err(gix_error)?;
            let commit = repository.find_commit(oid).map_err(gix_error)?;
            let after = base_snapshot(&repository, oid, &mut budget)?;
            let before = match commit.parent_ids().next() {
                Some(parent) => base_snapshot(&repository, parent.detach(), &mut budget)?,
                None => BTreeMap::new(),
            };
            (before, after)
        }
        "branch" => {
            let head = head.ok_or(GitDiffError::UnbornHead)?;
            let base = resolve_branch_commit(&repository, base_branch.unwrap_or("main"))?
                .ok_or(GitDiffError::NoRemoteBase)?;
            let merge_base = merge_base(&repository, head, base)?;
            (
                base_snapshot(&repository, merge_base, &mut budget)?,
                tracked_snapshot,
            )
        }
        _ => return Err(GitDiffError::NoRemoteBase),
    };
    Ok(snapshots)
}

fn encode_snapshot_diff(
    before: &BTreeMap<BString, FileEntry>,
    after: &BTreeMap<BString, FileEntry>,
) -> Result<String, GitDiffError> {
    validate_content_attributes(&before)?;
    validate_content_attributes(&after)?;
    let mut output = Vec::new();
    append_map_diff(&before, &after, &mut output)?;
    String::from_utf8(output).map_err(|error| GitDiffError::NonUtf8Content {
        path: BString::from(error.into_bytes()),
    })
}

fn resolve_branch_commit(
    repository: &gix::Repository,
    branch: &str,
) -> Result<Option<ObjectId>, GitDiffError> {
    let candidates = if branch.starts_with("refs/") {
        vec![branch.to_owned()]
    } else if branch.contains('/') {
        vec![
            format!("refs/heads/{branch}"),
            format!("refs/remotes/{branch}"),
        ]
    } else {
        vec![
            format!("refs/heads/{branch}"),
            format!("refs/remotes/origin/{branch}"),
        ]
    };
    for candidate in candidates {
        if let Some(id) = reference_commit(repository, &candidate)? {
            return Ok(Some(id));
        }
    }
    Ok(None)
}

fn merge_base(
    repository: &gix::Repository,
    head: ObjectId,
    base: ObjectId,
) -> Result<ObjectId, GitDiffError> {
    let mut head_ancestors = HashSet::new();
    for info in repository
        .find_commit(head)
        .map_err(gix_error)?
        .ancestors()
        .all()
        .map_err(gix_error)?
    {
        let info = info.map_err(gix_error)?;
        if head_ancestors.len() >= MAX_COMMITS {
            return Err(GitDiffError::BudgetExceeded("commit traversal"));
        }
        head_ancestors.insert(info.id);
    }
    for info in repository
        .find_commit(base)
        .map_err(gix_error)?
        .ancestors()
        .all()
        .map_err(gix_error)?
    {
        let info = info.map_err(gix_error)?;
        if head_ancestors.contains(&info.id) {
            return Ok(info.id);
        }
    }
    Err(GitDiffError::NoRemoteBase)
}

pub(super) fn merge_base_sha(
    cwd: &Path,
    base_branch: &str,
) -> Result<Option<String>, GitDiffError> {
    let repository = gix::discover(cwd).map_err(|_| GitDiffError::NotRepository)?;
    let head = match repository.head_id() {
        Ok(head) => head.detach(),
        Err(_) => return Ok(None),
    };
    let Some(base) = resolve_branch_commit(&repository, base_branch)? else {
        return Ok(None);
    };
    match merge_base(&repository, head, base) {
        Ok(id) => Ok(Some(id.to_string())),
        Err(GitDiffError::NoRemoteBase) => Ok(None),
        Err(error) => Err(error),
    }
}

pub(super) fn status_counts(
    cwd: &Path,
    include_untracked: bool,
) -> Result<GitStatusCounts, GitDiffError> {
    let repository = gix::discover(cwd).map_err(|_| GitDiffError::NotRepository)?;
    let workdir = repository
        .workdir()
        .ok_or(GitDiffError::BareRepository)?
        .to_owned();
    let index = repository.index_or_empty().map_err(gix_error)?;
    validate_index(&index)?;
    let mut budget = ReadBudget::default();
    let staged_snapshot = snapshot_index(&repository, &index, &mut budget)?;
    let head_snapshot = match repository.head_id() {
        Ok(head) => base_snapshot(&repository, head.detach(), &mut budget)?,
        Err(_) => BTreeMap::new(),
    };
    let worktree_snapshot = tracked_worktree_snapshot(&repository, &workdir, &index, &mut budget)?;
    let untracked = if include_untracked {
        untracked_snapshot(&repository, &workdir, &index, &mut budget)?.len()
    } else {
        0
    };
    Ok(GitStatusCounts {
        staged: changed_path_count(&head_snapshot, &staged_snapshot),
        unstaged: changed_path_count(&staged_snapshot, &worktree_snapshot),
        untracked,
    })
}

pub(super) fn review_summary(
    cwd: &Path,
    source: &str,
    commit_sha: Option<&str>,
    base_branch: Option<&str>,
    requested_paths: &[String],
    include_untracked: bool,
) -> Result<Value, GitDiffError> {
    let (before, after) = comparison_snapshots(cwd, source, commit_sha, base_branch)?;
    let requested = requested_paths
        .iter()
        .map(|path| BString::from(path.as_str()))
        .collect::<BTreeSet<_>>();
    let selected = |path: &BString| requested.is_empty() || requested.contains(path);
    let mut files = Vec::new();
    for path in before.keys().chain(after.keys()).collect::<BTreeSet<_>>() {
        if !selected(path) {
            continue;
        }
        let old = before.get(path);
        let new = after.get(path);
        if old == new {
            continue;
        }
        let (status, kind) = match (old, new) {
            (None, Some(_)) => ("A", "added"),
            (Some(_), None) => ("D", "deleted"),
            (Some(old), Some(new)) if old.mode != new.mode && old.data == new.data => {
                ("T", "type-changed")
            }
            _ => ("M", "modified"),
        };
        let (additions, deletions) = line_stats(old, new);
        let path = path
            .as_bstr()
            .to_str()
            .map_err(|_| GitDiffError::NonUtf8Reference)?;
        files.push(json!({
            "additions": additions,
            "changeKind": kind,
            "deletions": deletions,
            "path": path,
            "previousPath": null,
            "revision": format!(
                "{source}:{status}:{}:{}:{}:{}",
                mode_string(old),
                oid_string(old),
                mode_string(new),
                oid_string(new)
            ),
        }));
    }

    let repository = gix::discover(cwd).map_err(|_| GitDiffError::NotRepository)?;
    let workdir = repository
        .workdir()
        .ok_or(GitDiffError::BareRepository)?
        .to_owned();
    let index = repository.index_or_empty().map_err(gix_error)?;
    validate_index(&index)?;
    let mut budget = ReadBudget::default();
    let untracked = if include_untracked && matches!(source, "branch" | "uncommitted" | "unstaged")
    {
        untracked_snapshot(&repository, &workdir, &index, &mut budget)?
            .into_iter()
            .filter(|(path, _)| selected(path))
            .collect::<BTreeMap<_, _>>()
    } else {
        BTreeMap::new()
    };
    let untracked_count = untracked.len();
    let untracked_omitted = (untracked_count > 512).then(|| {
        json!({
            "count": untracked_count,
            "limit": 512,
        })
    });
    if untracked_omitted.is_none() {
        for (path, entry) in untracked {
            let path = path
                .as_bstr()
                .to_str()
                .map_err(|_| GitDiffError::NonUtf8Reference)?;
            files.push(json!({
                "additions": logical_line_count(&entry.data),
                "changeKind": "untracked",
                "deletions": 0,
                "path": path,
                "previousPath": null,
                "revision": format!(
                    "untracked:{:06o}:{}",
                    entry.mode.bits(),
                    entry.oid
                ),
            }));
        }
    }
    files.sort_by(|left, right| left["path"].as_str().cmp(&right["path"].as_str()));
    let counts = status_counts(cwd, include_untracked)?;
    let generation = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|error| GitDiffError::Gix(error.to_string()))?
        .as_millis();
    let mut response = json!({
        "type": "success",
        "files": files,
        "snapshotGeneration": generation,
        "source": source,
        "stageCounts": {
            "stagedFileCount": counts.staged,
            "unstagedFileCount": counts.unstaged,
            "untrackedFileCount": counts.untracked.max(untracked_count),
        },
    });
    if let Some(omitted) = untracked_omitted {
        response["untrackedFilesOmitted"] = omitted;
    }
    Ok(response)
}

pub(super) fn review_action_patch(
    cwd: &Path,
    source: &str,
    requested_paths: &[String],
) -> Result<String, GitDiffError> {
    let (before, mut after) = comparison_snapshots(cwd, source, None, None)?;
    let requested = requested_paths
        .iter()
        .map(|path| BString::from(path.as_str()))
        .collect::<BTreeSet<_>>();
    if matches!(source, "unstaged" | "uncommitted") {
        let repository = gix::discover(cwd).map_err(|_| GitDiffError::NotRepository)?;
        let workdir = repository
            .workdir()
            .ok_or(GitDiffError::BareRepository)?
            .to_owned();
        let index = repository.index_or_empty().map_err(gix_error)?;
        validate_index(&index)?;
        let mut budget = ReadBudget::default();
        for (path, entry) in untracked_snapshot(&repository, &workdir, &index, &mut budget)? {
            if requested.contains(&path) {
                after.insert(path, entry);
            }
        }
    }
    let selected_before = before
        .into_iter()
        .filter(|(path, _)| requested.contains(path))
        .collect();
    let selected_after = after
        .into_iter()
        .filter(|(path, _)| requested.contains(path))
        .collect();
    encode_snapshot_diff(&selected_before, &selected_after)
}

fn mode_string(entry: Option<&FileEntry>) -> String {
    entry.map_or_else(
        || "000000".to_owned(),
        |entry| format!("{:06o}", entry.mode.bits()),
    )
}

fn oid_string(entry: Option<&FileEntry>) -> String {
    entry.map_or_else(
        || "0000000000000000000000000000000000000000".to_owned(),
        |entry| entry.oid.to_string(),
    )
}

fn logical_line_count(data: &[u8]) -> usize {
    if data.is_empty() {
        0
    } else {
        data.split(|byte| *byte == b'\n').count() - usize::from(data.ends_with(b"\n"))
    }
}

fn line_stats(old: Option<&FileEntry>, new: Option<&FileEntry>) -> (usize, usize) {
    let old_data = old.map_or(&[][..], |entry| entry.data.as_slice());
    let new_data = new.map_or(&[][..], |entry| entry.data.as_slice());
    if old_data.contains(&0) || new_data.contains(&0) {
        return (0, 0);
    }
    let Ok(hunks) = unified_hunks(old_data, new_data) else {
        return (0, 0);
    };
    let mut additions = 0;
    let mut deletions = 0;
    for line in hunks.split(|byte| *byte == b'\n') {
        match line.first() {
            Some(b'+') => additions += 1,
            Some(b'-') => deletions += 1,
            _ => {}
        }
    }
    (additions, deletions)
}

fn changed_path_count(
    left: &BTreeMap<BString, FileEntry>,
    right: &BTreeMap<BString, FileEntry>,
) -> usize {
    left.keys()
        .chain(right.keys())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .filter(|path| left.get(*path) != right.get(*path))
        .count()
}

pub(super) fn request(params: &serde_json::Value) -> Result<Vec<u8>, CoreError> {
    let params: GitDiffParams =
        serde_json::from_value(params.clone()).map_err(|_| CoreError::InvalidArgument)?;
    if params.cwd.trim().is_empty() {
        return Err(CoreError::InvalidArgument);
    }
    let result =
        git_diff_to_remote(Path::new(&params.cwd)).map_err(|_| CoreError::InvalidArgument)?;
    serde_json::to_vec(&result).map_err(|_| CoreError::InvalidJson)
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct FileEntry {
    mode: Mode,
    oid: ObjectId,
    data: Vec<u8>,
}

#[derive(Default)]
struct ReadBudget {
    files: usize,
    bytes: usize,
}

impl ReadBudget {
    fn ensure_can_charge(&self, bytes: usize) -> Result<(), GitDiffError> {
        if bytes > MAX_FILE_BYTES {
            return Err(GitDiffError::BudgetExceeded("file size"));
        }
        if self.files >= MAX_FILES {
            return Err(GitDiffError::BudgetExceeded("file count"));
        }
        if bytes > MAX_TOTAL_BYTES.saturating_sub(self.bytes) {
            return Err(GitDiffError::BudgetExceeded("total bytes"));
        }
        Ok(())
    }

    fn charge(&mut self, bytes: usize) -> Result<(), GitDiffError> {
        self.ensure_can_charge(bytes)?;
        self.files += 1;
        self.bytes += bytes;
        Ok(())
    }

    fn maximum_next_read(&self) -> Result<usize, GitDiffError> {
        self.ensure_can_charge(0)?;
        Ok(MAX_FILE_BYTES
            .min(MAX_TOTAL_BYTES.saturating_sub(self.bytes))
            .saturating_add(1))
    }
}

#[derive(Clone, Debug)]
struct SelectedRemote {
    sha: ObjectId,
    distance: usize,
}

fn git_diff_to_remote(cwd: &Path) -> Result<GitDiffResponse, GitDiffError> {
    let repository = gix::discover(cwd).map_err(|_| GitDiffError::NotRepository)?;
    let workdir = repository
        .workdir()
        .ok_or(GitDiffError::BareRepository)?
        .to_owned();
    if repository.object_hash() != gix::hash::Kind::Sha1 {
        return Err(GitDiffError::UnsupportedHash);
    }
    validate_repository_configuration(&repository)?;
    let head = repository
        .head_id()
        .map_err(|_| GitDiffError::UnbornHead)?
        .detach();
    let selected = select_remote(&repository, head)?;
    let mut budget = ReadBudget::default();
    let base = base_snapshot(&repository, selected.sha, &mut budget)?;
    validate_content_attributes(&base)?;
    let index = repository.index_or_empty().map_err(gix_error)?;
    validate_index(&index)?;
    let tracked = tracked_worktree_snapshot(&repository, &workdir, &index, &mut budget)?;
    validate_content_attributes(&tracked)?;
    let untracked = untracked_snapshot(&repository, &workdir, &index, &mut budget)?;
    validate_content_attributes(&untracked)?;

    let mut diff = Vec::new();
    append_map_diff(&base, &tracked, &mut diff)?;
    append_map_diff(&BTreeMap::new(), &untracked, &mut diff)?;
    let diff = String::from_utf8(diff).map_err(|error| GitDiffError::NonUtf8Content {
        path: BString::from(error.into_bytes()),
    })?;
    Ok(GitDiffResponse {
        sha: selected.sha.to_string(),
        diff,
    })
}

fn validate_repository_configuration(repository: &gix::Repository) -> Result<(), GitDiffError> {
    let config = repository.config_snapshot();
    for (key, supported_value, display_key) in [
        ("core.autocrlf", false, "core.autocrlf"),
        ("core.filemode", true, "core.filemode"),
        ("core.symlinks", true, "core.symlinks"),
        ("core.quotepath", true, "core.quotePath"),
    ] {
        if let Some(value) = config.try_boolean(key)
            && !matches!(value, Ok(value) if value == supported_value)
        {
            return Err(GitDiffError::UnsupportedConfiguration { key: display_key });
        }
    }
    for (key, display_key) in [
        ("core.eol", "core.eol"),
        ("core.attributesfile", "core.attributesFile"),
        ("core.abbrev", "core.abbrev"),
        ("diff.algorithm", "diff.algorithm"),
        ("diff.context", "diff.context"),
        ("diff.interhunkcontext", "diff.interHunkContext"),
        ("diff.renames", "diff.renames"),
        ("diff.noprefix", "diff.noPrefix"),
        ("diff.srcprefix", "diff.srcPrefix"),
        ("diff.dstprefix", "diff.dstPrefix"),
        ("diff.lineprefix", "diff.linePrefix"),
        ("diff.mnemonicprefix", "diff.mnemonicPrefix"),
        ("diff.relative", "diff.relative"),
        ("diff.orderfile", "diff.orderFile"),
        ("diff.indentheuristic", "diff.indentHeuristic"),
        ("diff.compactionheuristic", "diff.compactionHeuristic"),
        ("diff.minimal", "diff.minimal"),
    ] {
        if config.string(key).is_some() {
            return Err(GitDiffError::UnsupportedConfiguration { key: display_key });
        }
    }

    let has_local_clean_filter =
        config
            .plumbing()
            .sections_by_name("filter")
            .is_some_and(|sections| {
                sections
                    .filter(|section| {
                        section.meta().source.kind() == gix::config::source::Kind::Repository
                    })
                    .any(|section| {
                        section.body().contains_value_name("clean")
                            || section.body().contains_value_name("process")
                    })
            });
    if has_local_clean_filter {
        return Err(GitDiffError::UnsupportedConfiguration { key: "filter.*" });
    }

    for attributes in [
        repository.common_dir().join("info/attributes"),
        repository.git_dir().join("info/attributes"),
    ] {
        match fs::symlink_metadata(&attributes) {
            Ok(metadata) if metadata.len() != 0 || !metadata.file_type().is_file() => {
                return Err(GitDiffError::UnsupportedConfiguration {
                    key: ".git/info/attributes",
                });
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(io_error(attributes)(error)),
        }
    }
    Ok(())
}

fn utf8_reference(bytes: &[u8]) -> Result<String, GitDiffError> {
    std::str::from_utf8(bytes)
        .map(str::to_owned)
        .map_err(|_| GitDiffError::NonUtf8Reference)
}

fn remote_names(repository: &gix::Repository) -> Result<Vec<String>, GitDiffError> {
    let mut names = repository
        .remote_names()
        .iter()
        .map(|name| utf8_reference(name.as_ref()))
        .collect::<Result<Vec<_>, _>>()?;
    names.sort();
    if let Some(position) = names.iter().position(|name| name == "origin") {
        let origin = names.remove(position);
        names.insert(0, origin);
    }
    Ok(names)
}

fn current_branch(repository: &gix::Repository) -> Result<Option<String>, GitDiffError> {
    let head = repository.head().map_err(gix_error)?;
    let Some(name) = head.referent_name() else {
        return Ok(None);
    };
    name.as_bstr()
        .as_bytes()
        .strip_prefix(b"refs/heads/")
        .map(utf8_reference)
        .transpose()
}

fn default_branch(
    repository: &gix::Repository,
    remotes: &[String],
) -> Result<Option<String>, GitDiffError> {
    for remote in remotes {
        let reference_name = format!("refs/remotes/{remote}/HEAD");
        let Some(reference) = repository
            .try_find_reference(reference_name.as_str())
            .map_err(gix_error)?
        else {
            continue;
        };
        if let gix::refs::TargetRef::Symbolic(target) = reference.target() {
            let target = utf8_reference(target.as_bstr().as_bytes())?;
            if let Some((_, leaf)) = target.rsplit_once('/') {
                return Ok(Some(leaf.to_owned()));
            }
        }
    }
    for local in ["main", "master"] {
        if repository
            .try_find_reference(format!("refs/heads/{local}").as_str())
            .map_err(gix_error)?
            .is_some()
        {
            return Ok(Some(local.to_owned()));
        }
    }
    Ok(None)
}

fn contains_commit(
    repository: &gix::Repository,
    tip: ObjectId,
    needle: ObjectId,
) -> Result<bool, GitDiffError> {
    let mut visited = 0usize;
    for info in repository
        .find_commit(tip)
        .map_err(gix_error)?
        .ancestors()
        .all()
        .map_err(gix_error)?
    {
        let info = info.map_err(gix_error)?;
        visited += 1;
        if visited > MAX_COMMITS {
            return Err(GitDiffError::BudgetExceeded("commit traversal"));
        }
        if info.id == needle {
            return Ok(true);
        }
    }
    Ok(false)
}

fn containing_remote_branches(
    repository: &gix::Repository,
    remotes: &[String],
    head: ObjectId,
) -> Result<Vec<String>, GitDiffError> {
    let mut references = Vec::<(String, ObjectId)>::new();
    let platform = repository.references().map_err(gix_error)?;
    let iterator = platform
        .remote_branches()
        .map_err(gix_error)?
        .peeled()
        .map_err(gix_error)?;
    for reference in iterator {
        if references.len() >= MAX_FILES {
            return Err(GitDiffError::BudgetExceeded("reference count"));
        }
        let reference = reference.map_err(gix_error)?;
        let name = utf8_reference(reference.name().as_bstr().as_bytes())?;
        let Some(id) = reference.try_id() else {
            continue;
        };
        references.push((name, id.detach()));
    }
    references.sort_by(|left, right| left.0.cmp(&right.0));

    let mut branches = Vec::new();
    let mut seen = HashSet::new();
    for remote in remotes {
        let prefix = format!("refs/remotes/{remote}/");
        for (name, tip) in &references {
            let Some(branch) = name.strip_prefix(&prefix) else {
                continue;
            };
            if !branch.is_empty()
                && contains_commit(repository, *tip, head)?
                && seen.insert(branch.to_owned())
            {
                branches.push(branch.to_owned());
            }
        }
    }
    Ok(branches)
}

fn reference_commit(
    repository: &gix::Repository,
    name: &str,
) -> Result<Option<ObjectId>, GitDiffError> {
    let Some(mut reference) = repository.try_find_reference(name).map_err(gix_error)? else {
        return Ok(None);
    };
    Ok(Some(
        reference.peel_to_commit().map_err(gix_error)?.id().detach(),
    ))
}

fn commit_distance(
    repository: &gix::Repository,
    head: ObjectId,
    hidden: ObjectId,
) -> Result<usize, GitDiffError> {
    let mut count = 0usize;
    for info in repository
        .find_commit(head)
        .map_err(gix_error)?
        .ancestors()
        .with_hidden([hidden])
        .all()
        .map_err(gix_error)?
    {
        info.map_err(gix_error)?;
        count += 1;
        if count > MAX_COMMITS {
            return Err(GitDiffError::BudgetExceeded("commit traversal"));
        }
    }
    Ok(count)
}

fn branch_remote_and_distance(
    repository: &gix::Repository,
    branch: &str,
    remotes: &[String],
    head: ObjectId,
) -> Result<Option<SelectedRemote>, GitDiffError> {
    let mut remote_sha = None;
    for remote in remotes {
        let name = format!("refs/remotes/{remote}/{branch}");
        if let Some(id) = reference_commit(repository, &name)? {
            remote_sha = Some(id);
            break;
        }
    }
    let Some(remote_sha) = remote_sha else {
        return Ok(None);
    };
    let local_name = format!("refs/heads/{branch}");
    let distance = match reference_commit(repository, &local_name) {
        Ok(Some(local_sha)) => commit_distance(repository, head, local_sha)
            .or_else(|_| commit_distance(repository, head, remote_sha))?,
        Ok(None) | Err(_) => commit_distance(repository, head, remote_sha)?,
    };
    Ok(Some(SelectedRemote {
        sha: remote_sha,
        distance,
    }))
}

fn select_remote(
    repository: &gix::Repository,
    head: ObjectId,
) -> Result<SelectedRemote, GitDiffError> {
    let remotes = remote_names(repository)?;
    if remotes.is_empty() {
        return Err(GitDiffError::NoRemoteBase);
    }
    let mut branches = Vec::new();
    let mut seen = HashSet::new();
    if let Some(branch) = current_branch(repository)? {
        seen.insert(branch.clone());
        branches.push(branch);
    }
    if let Some(branch) = default_branch(repository, &remotes)?
        && seen.insert(branch.clone())
    {
        branches.push(branch);
    }
    for branch in containing_remote_branches(repository, &remotes, head)? {
        if seen.insert(branch.clone()) {
            branches.push(branch);
        }
    }

    let mut closest: Option<SelectedRemote> = None;
    for branch in branches {
        let Some(candidate) = branch_remote_and_distance(repository, &branch, &remotes, head)?
        else {
            continue;
        };
        if closest
            .as_ref()
            .is_none_or(|selected| candidate.distance < selected.distance)
        {
            closest = Some(candidate);
        }
    }
    closest.ok_or(GitDiffError::NoRemoteBase)
}

fn validate_index(index: &gix::index::State) -> Result<(), GitDiffError> {
    if index.is_sparse() {
        return Err(GitDiffError::SparseIndex { path: None });
    }
    for entry in index.entries() {
        let path = entry.path(index).to_owned();
        if entry.stage() != Stage::Unconflicted {
            return Err(GitDiffError::UnmergedIndex { path });
        }
        if entry.mode == Mode::COMMIT {
            return Err(GitDiffError::Gitlink { path });
        }
        if entry.mode == Mode::DIR || entry.flags.contains(Flags::SKIP_WORKTREE) {
            return Err(GitDiffError::SparseIndex { path: Some(path) });
        }
        if entry.flags.contains(Flags::INTENT_TO_ADD) {
            return Err(GitDiffError::IntentToAdd { path });
        }
    }
    Ok(())
}

fn base_snapshot(
    repository: &gix::Repository,
    sha: ObjectId,
    budget: &mut ReadBudget,
) -> Result<BTreeMap<BString, FileEntry>, GitDiffError> {
    let tree = repository
        .find_commit(sha)
        .map_err(gix_error)?
        .tree()
        .map_err(gix_error)?;
    let flattened = repository
        .index_from_tree(&tree.id().detach())
        .map_err(gix_error)?;
    snapshot_index(repository, &flattened, budget)
}

fn snapshot_index(
    repository: &gix::Repository,
    index: &gix::index::State,
    budget: &mut ReadBudget,
) -> Result<BTreeMap<BString, FileEntry>, GitDiffError> {
    let mut snapshot = BTreeMap::new();
    for entry in index.entries() {
        let path = entry.path(index).to_owned();
        if entry.mode == Mode::COMMIT {
            return Err(GitDiffError::Gitlink { path });
        }
        if entry.mode == Mode::DIR {
            return Err(GitDiffError::SparseIndex { path: Some(path) });
        }
        let data = read_blob_with_budget(repository, entry.id, budget)?;
        snapshot.insert(
            path,
            FileEntry {
                mode: entry.mode,
                oid: entry.id,
                data,
            },
        );
    }
    Ok(snapshot)
}

fn read_blob_with_budget(
    repository: &gix::Repository,
    id: ObjectId,
    budget: &mut ReadBudget,
) -> Result<Vec<u8>, GitDiffError> {
    let size = usize::try_from(repository.find_header(id).map_err(gix_error)?.size())
        .map_err(|_| GitDiffError::BudgetExceeded("file size"))?;
    budget.ensure_can_charge(size)?;
    let data = repository.find_blob(id).map_err(gix_error)?.data.to_vec();
    budget.charge(data.len())?;
    Ok(data)
}

fn tracked_worktree_snapshot(
    repository: &gix::Repository,
    workdir: &Path,
    index: &gix::index::State,
    budget: &mut ReadBudget,
) -> Result<BTreeMap<BString, FileEntry>, GitDiffError> {
    let mut snapshot = BTreeMap::new();
    for entry in index.entries() {
        let relative = entry.path(index).to_owned();
        if entry.flags.contains(Flags::ASSUME_VALID) {
            let data = read_blob_with_budget(repository, entry.id, budget)?;
            snapshot.insert(
                relative,
                FileEntry {
                    mode: entry.mode,
                    oid: entry.id,
                    data,
                },
            );
            continue;
        }
        if let Some(entry) = read_worktree_entry(repository, workdir, relative.as_ref(), budget)? {
            snapshot.insert(relative, entry);
        }
    }
    Ok(snapshot)
}

fn validate_leading_components(workdir: &Path, relative: &BStr) -> Result<(), GitDiffError> {
    let relative_path = gix::path::from_bstr(relative);
    let mut components = relative_path.components().peekable();
    let mut checked_path = PathBuf::new();
    let mut absolute_path = workdir.to_owned();
    while let Some(component) = components.next() {
        if components.peek().is_none() {
            break;
        }
        let Component::Normal(component) = component else {
            return Err(GitDiffError::UnsupportedFileType {
                path: relative.to_owned(),
            });
        };
        checked_path.push(component);
        absolute_path.push(component);
        match fs::symlink_metadata(&absolute_path) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                return Err(GitDiffError::LeadingDirectorySymlink {
                    path: BString::from(checked_path.as_os_str().as_bytes().to_vec()),
                });
            }
            Ok(metadata) if !metadata.file_type().is_dir() => {
                return Err(GitDiffError::UnsupportedFileType {
                    path: BString::from(checked_path.as_os_str().as_bytes().to_vec()),
                });
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(error) => return Err(io_error(absolute_path)(error)),
        }
    }
    Ok(())
}

fn read_regular_file_with_budget(
    path: &Path,
    reported_length: usize,
    budget: &mut ReadBudget,
) -> Result<Vec<u8>, GitDiffError> {
    budget.ensure_can_charge(reported_length)?;
    let maximum_read = budget.maximum_next_read()?;
    let mut data = Vec::with_capacity(reported_length.min(maximum_read));
    fs::File::open(path)
        .map_err(io_error(path))?
        .take(maximum_read as u64)
        .read_to_end(&mut data)
        .map_err(io_error(path))?;
    budget.charge(data.len())?;
    Ok(data)
}

fn read_worktree_entry(
    repository: &gix::Repository,
    workdir: &Path,
    relative: &BStr,
    budget: &mut ReadBudget,
) -> Result<Option<FileEntry>, GitDiffError> {
    validate_leading_components(workdir, relative)?;
    let path = workdir.join(gix::path::from_bstr(relative));
    let metadata = match fs::symlink_metadata(&path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(io_error(path)(error)),
    };
    let file_type = metadata.file_type();
    let (mode, data) = if file_type.is_symlink() {
        let length = usize::try_from(metadata.len())
            .map_err(|_| GitDiffError::BudgetExceeded("file size"))?;
        budget.ensure_can_charge(length)?;
        let target = fs::read_link(&path).map_err(io_error(&path))?;
        let data = target.as_os_str().as_bytes().to_vec();
        budget.charge(data.len())?;
        (Mode::SYMLINK, data)
    } else if file_type.is_file() {
        let length = usize::try_from(metadata.len())
            .map_err(|_| GitDiffError::BudgetExceeded("file size"))?;
        let mode = if metadata.permissions().mode() & 0o111 == 0 {
            Mode::FILE
        } else {
            Mode::FILE_EXECUTABLE
        };
        (mode, read_regular_file_with_budget(&path, length, budget)?)
    } else {
        return Err(GitDiffError::UnsupportedFileType {
            path: relative.to_owned(),
        });
    };
    let oid = gix::objs::compute_hash(repository.object_hash(), gix::objs::Kind::Blob, &data)
        .map_err(gix_error)?;
    Ok(Some(FileEntry { mode, oid, data }))
}

fn untracked_snapshot(
    repository: &gix::Repository,
    workdir: &Path,
    index: &gix::index::State,
    budget: &mut ReadBudget,
) -> Result<BTreeMap<BString, FileEntry>, GitDiffError> {
    let worktree = repository.worktree().ok_or(GitDiffError::BareRepository)?;
    let mut excludes = worktree.excludes(None).map_err(gix_error)?;
    let tracked: BTreeSet<BString> = index
        .entries()
        .iter()
        .map(|entry| entry.path(index).to_owned())
        .collect();
    let mut snapshot = BTreeMap::new();
    scan_untracked_directory(
        repository,
        workdir,
        Path::new(""),
        &tracked,
        &mut excludes,
        budget,
        &mut snapshot,
    )?;
    Ok(snapshot)
}

#[allow(clippy::too_many_arguments)]
fn scan_untracked_directory(
    repository: &gix::Repository,
    workdir: &Path,
    relative_directory: &Path,
    tracked: &BTreeSet<BString>,
    excludes: &mut gix::AttributeStack<'_>,
    budget: &mut ReadBudget,
    snapshot: &mut BTreeMap<BString, FileEntry>,
) -> Result<(), GitDiffError> {
    let directory = workdir.join(relative_directory);
    let mut children = fs::read_dir(&directory)
        .map_err(io_error(&directory))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(io_error(&directory))?;
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
        let metadata = fs::symlink_metadata(child.path()).map_err(io_error(child.path()))?;
        let mode = if metadata.file_type().is_dir() {
            Mode::DIR
        } else if metadata.file_type().is_symlink() {
            Mode::SYMLINK
        } else {
            Mode::FILE
        };
        if excludes
            .at_path(&relative, Some(mode))
            .map_err(io_error(&relative))?
            .is_excluded()
        {
            continue;
        }
        if metadata.file_type().is_dir() {
            let marker = child.path().join(".git");
            match fs::symlink_metadata(&marker) {
                Ok(_) => {
                    return Err(GitDiffError::NestedRepository {
                        path: BString::from(relative.as_os_str().as_bytes().to_vec()),
                    });
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(io_error(marker)(error)),
            }
            scan_untracked_directory(
                repository, workdir, &relative, tracked, excludes, budget, snapshot,
            )?;
            continue;
        }
        let relative_bytes = BString::from(relative.as_os_str().as_bytes().to_vec());
        if tracked.contains(&relative_bytes) {
            continue;
        }
        let Some(entry) =
            read_worktree_entry(repository, workdir, relative_bytes.as_ref(), budget)?
        else {
            continue;
        };
        snapshot.insert(relative_bytes, entry);
    }
    Ok(())
}

fn validate_content_attributes(
    snapshot: &BTreeMap<BString, FileEntry>,
) -> Result<(), GitDiffError> {
    for (path, entry) in snapshot {
        if !path
            .as_bstr()
            .as_bytes()
            .rsplit(|byte| *byte == b'/')
            .next()
            .is_some_and(|name| name == b".gitattributes")
        {
            continue;
        }
        let text = std::str::from_utf8(&entry.data)
            .map_err(|_| GitDiffError::UnsupportedAttributes { path: path.clone() })?;
        for line in text.lines() {
            let line = line.trim_start();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            return Err(GitDiffError::UnsupportedAttributes { path: path.clone() });
        }
    }
    Ok(())
}

fn append_map_diff(
    before: &BTreeMap<BString, FileEntry>,
    after: &BTreeMap<BString, FileEntry>,
    output: &mut Vec<u8>,
) -> Result<(), GitDiffError> {
    let mut renamed_from = BTreeSet::new();
    let mut renamed_to = BTreeSet::new();
    for (old_path, old_entry) in before.iter().filter(|(path, _)| !after.contains_key(*path)) {
        let Some((new_path, _)) = after.iter().find(|(path, entry)| {
            !before.contains_key(*path) && !renamed_to.contains(*path) && *entry == old_entry
        }) else {
            continue;
        };
        let record = rename_record(old_path.as_ref(), new_path.as_ref());
        if output.len().saturating_add(record.len()) > MAX_DIFF_BYTES {
            return Err(GitDiffError::BudgetExceeded("diff size"));
        }
        output.extend_from_slice(&record);
        renamed_from.insert(old_path);
        renamed_to.insert(new_path);
    }

    let paths: BTreeSet<&BString> = before.keys().chain(after.keys()).collect();
    for path in paths {
        if renamed_from.contains(path) || renamed_to.contains(path) {
            continue;
        }
        let old = before.get(path);
        let new = after.get(path);
        if old == new {
            continue;
        }
        let binary = [old, new]
            .into_iter()
            .flatten()
            .any(|entry| entry.data.contains(&0));
        for entry in [old, new].into_iter().flatten() {
            if !binary && std::str::from_utf8(&entry.data).is_err() {
                return Err(GitDiffError::NonUtf8Content { path: path.clone() });
            }
        }
        let record = patch_record(path.as_ref(), old, new, binary)?;
        if output.len().saturating_add(record.len()) > MAX_DIFF_BYTES {
            return Err(GitDiffError::BudgetExceeded("diff size"));
        }
        output.extend_from_slice(&record);
    }
    Ok(())
}

fn rename_record(old_path: &BStr, new_path: &BStr) -> Vec<u8> {
    let mut output = Vec::new();
    output.extend_from_slice(b"diff --git ");
    output.extend_from_slice(&quote_git_path(b"a/", old_path));
    output.push(b' ');
    output.extend_from_slice(&quote_git_path(b"b/", new_path));
    output.push(b'\n');
    output.extend_from_slice(b"similarity index 100%\n");
    output.extend_from_slice(b"rename from ");
    output.extend_from_slice(&quote_git_path(b"", old_path));
    output.push(b'\n');
    output.extend_from_slice(b"rename to ");
    output.extend_from_slice(&quote_git_path(b"", new_path));
    output.push(b'\n');
    output
}

fn abbreviated_oid(oid: Option<ObjectId>) -> String {
    oid.map_or_else(
        || "0000000".to_owned(),
        |oid| oid.to_string().chars().take(7).collect(),
    )
}

fn patch_record(
    path: &BStr,
    old: Option<&FileEntry>,
    new: Option<&FileEntry>,
    binary: bool,
) -> Result<Vec<u8>, GitDiffError> {
    let a_path = quote_git_path(b"a/", path);
    let b_path = quote_git_path(b"b/", path);
    let mut output = Vec::new();
    output.extend_from_slice(b"diff --git ");
    output.extend_from_slice(&a_path);
    output.push(b' ');
    output.extend_from_slice(&b_path);
    output.push(b'\n');

    match (old, new) {
        (None, Some(entry)) => {
            extend_line(
                &mut output,
                format!("new file mode {:06o}", entry.mode.bits()),
            );
        }
        (Some(entry), None) => {
            extend_line(
                &mut output,
                format!("deleted file mode {:06o}", entry.mode.bits()),
            );
        }
        (Some(old), Some(new)) if old.mode != new.mode => {
            extend_line(&mut output, format!("old mode {:06o}", old.mode.bits()));
            extend_line(&mut output, format!("new mode {:06o}", new.mode.bits()));
        }
        _ => {}
    }

    let old_data = old.map_or(&[][..], |entry| entry.data.as_slice());
    let new_data = new.map_or(&[][..], |entry| entry.data.as_slice());
    if old_data != new_data {
        let old_oid = old.map(|entry| entry.oid);
        let new_oid = new.map(|entry| entry.oid);
        let suffix = match (old, new) {
            (Some(old), Some(new)) if old.mode == new.mode => {
                format!(" {:06o}", old.mode.bits())
            }
            _ => String::new(),
        };
        extend_line(
            &mut output,
            format!(
                "index {}..{}{}",
                abbreviated_oid(old_oid),
                abbreviated_oid(new_oid),
                suffix
            ),
        );
        if binary {
            output.extend_from_slice(b"GIT binary patch\n");
            output.extend_from_slice(&binary_literal(new_data)?);
            output.extend_from_slice(&binary_literal(old_data)?);
        } else {
            output.extend_from_slice(b"--- ");
            output.extend_from_slice(if old.is_some() { &a_path } else { b"/dev/null" });
            if old.is_some() && path.contains(&b' ') {
                output.push(b'\t');
            }
            output.push(b'\n');
            output.extend_from_slice(b"+++ ");
            output.extend_from_slice(if new.is_some() { &b_path } else { b"/dev/null" });
            if new.is_some() && path.contains(&b' ') {
                output.push(b'\t');
            }
            output.push(b'\n');
            output.extend_from_slice(&unified_hunks(old_data, new_data)?);
        }
    }
    Ok(output)
}

const GIT_BASE85: &[u8; 85] =
    b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!#$%&()*+-;<=>?@^_`{|}~";

fn binary_literal(data: &[u8]) -> Result<Vec<u8>, GitDiffError> {
    let mut encoder = ZlibEncoder::new(Vec::new(), Compression::default());
    encoder
        .write_all(data)
        .map_err(io_error("<binary-patch>"))?;
    let compressed = encoder.finish().map_err(io_error("<binary-patch>"))?;
    let mut output = format!("literal {}\n", data.len()).into_bytes();
    for chunk in compressed.chunks(52) {
        output.push(match chunk.len() {
            1..=26 => b'A' + chunk.len() as u8 - 1,
            27..=52 => b'a' + chunk.len() as u8 - 27,
            _ => return Err(GitDiffError::BudgetExceeded("binary patch line")),
        });
        for group in chunk.chunks(4) {
            let mut bytes = [0u8; 4];
            bytes[..group.len()].copy_from_slice(group);
            let mut value = u32::from_be_bytes(bytes);
            let mut encoded = [0u8; 5];
            for slot in encoded.iter_mut().rev() {
                *slot = GIT_BASE85[(value % 85) as usize];
                value /= 85;
            }
            output.extend_from_slice(&encoded);
        }
        output.push(b'\n');
    }
    output.push(b'\n');
    Ok(output)
}

fn extend_line(output: &mut Vec<u8>, line: String) {
    output.extend_from_slice(line.as_bytes());
    output.push(b'\n');
}

#[derive(Default)]
struct PatchHunks(Vec<u8>);

impl ConsumeHunk for PatchHunks {
    type Out = Vec<u8>;

    fn consume_hunk(
        &mut self,
        header: HunkHeader,
        lines: &[(DiffLineKind, &[u8])],
    ) -> std::io::Result<()> {
        extend_line(
            &mut self.0,
            format!(
                "@@ -{} +{} @@",
                format_hunk_range(header.before_hunk_start, header.before_hunk_len),
                format_hunk_range(header.after_hunk_start, header.after_hunk_len)
            ),
        );
        for (kind, line) in lines {
            self.0.push(kind.to_prefix() as u8);
            self.0.extend_from_slice(line);
            if !line.ends_with(b"\n") {
                self.0.push(b'\n');
                self.0.extend_from_slice(b"\\ No newline at end of file\n");
            }
        }
        Ok(())
    }

    fn finish(self) -> Self::Out {
        self.0
    }
}

fn format_hunk_range(start: u32, length: u32) -> String {
    match length {
        0 => format!("{},0", start.saturating_sub(1)),
        1 => start.to_string(),
        _ => format!("{start},{length}"),
    }
}

fn unified_hunks(before: &[u8], after: &[u8]) -> Result<Vec<u8>, GitDiffError> {
    let input = InternedInput::new(
        byte_lines_with_terminator(before),
        byte_lines_with_terminator(after),
    );
    let consumer = UnifiedDiff::new(
        &input,
        PatchHunks::default(),
        ContextSize::symmetrical(CONTEXT_LINES),
    );
    gix::diff::blob::diff(Algorithm::Myers, &input, consumer).map_err(io_error("<unified-diff>"))
}

pub(super) fn text_hunks(before: &[u8], after: &[u8]) -> Result<Vec<u8>, GitDiffError> {
    unified_hunks(before, after)
}

fn quote_git_path(prefix: &[u8], path: &BStr) -> Vec<u8> {
    let mut raw = Vec::with_capacity(prefix.len() + path.len());
    raw.extend_from_slice(prefix);
    raw.extend_from_slice(path);
    if raw
        .iter()
        .all(|byte| matches!(byte, 0x20..=0x7e) && !matches!(byte, b'\\' | b'"'))
    {
        return raw;
    }
    let mut output = vec![b'"'];
    for byte in raw {
        match byte {
            b'\\' | b'"' => {
                output.push(b'\\');
                output.push(byte);
            }
            0x07 => output.extend_from_slice(b"\\a"),
            0x08 => output.extend_from_slice(b"\\b"),
            b'\n' => output.extend_from_slice(b"\\n"),
            0x0b => output.extend_from_slice(b"\\v"),
            0x0c => output.extend_from_slice(b"\\f"),
            b'\r' => output.extend_from_slice(b"\\r"),
            b'\t' => output.extend_from_slice(b"\\t"),
            0x20..=0x7e => output.push(byte),
            byte => output.extend_from_slice(format!("\\{byte:03o}").as_bytes()),
        }
    }
    output.push(b'"');
    output
}

#[cfg(test)]
mod tests {
    use super::{GitDiffError, git_diff_to_remote};
    use crate::{CodexCore, CoreError};
    use std::fs;
    use std::os::unix::fs::symlink;
    use std::path::Path;
    use std::process::Command;

    fn git(cwd: &Path, args: &[&str]) -> String {
        let output = Command::new("git")
            .current_dir(cwd)
            .args(args)
            .output()
            .expect("git fixture command starts");
        assert!(
            output.status.success(),
            "git {:?} failed:\n{}",
            args,
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout)
            .expect("git fixture output is UTF-8")
            .trim()
            .to_owned()
    }

    fn git_diff_output(cwd: &Path, args: &[&str], expected_code: i32) -> String {
        let output = Command::new("git")
            .current_dir(cwd)
            .args(args)
            .output()
            .expect("git diff fixture command starts");
        assert_eq!(
            output.status.code(),
            Some(expected_code),
            "git {:?} failed:\n{}",
            args,
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout).expect("git diff output is UTF-8")
    }

    fn repository() -> tempfile::TempDir {
        let directory = tempfile::tempdir().expect("temp repository");
        git(directory.path(), &["init", "-b", "main"]);
        git(
            directory.path(),
            &["config", "user.email", "fixture@example.invalid"],
        );
        git(directory.path(), &["config", "user.name", "Fixture"]);
        fs::write(directory.path().join("story.txt"), "first\nsecond\n")
            .expect("write tracked fixture");
        for name in ["staged.txt", "combined.txt", "unstaged.txt", "deleted.txt"] {
            fs::write(directory.path().join(name), format!("base {name}\n"))
                .expect("write tracked fixture");
        }
        symlink("old-target", directory.path().join("story-link")).expect("write base symlink");
        git(directory.path(), &["add", "."]);
        git(directory.path(), &["commit", "-m", "base"]);
        git(directory.path(), &["remote", "add", "origin", "."]);
        git(
            directory.path(),
            &["update-ref", "refs/remotes/origin/main", "refs/heads/main"],
        );
        git(
            directory.path(),
            &[
                "symbolic-ref",
                "refs/remotes/origin/HEAD",
                "refs/remotes/origin/main",
            ],
        );
        directory
    }

    #[test]
    fn clean_repository_returns_selected_remote_sha_and_empty_diff() {
        let repository = repository();
        let expected_sha = git(
            repository.path(),
            &["rev-parse", "refs/remotes/origin/main"],
        );

        let response = git_diff_to_remote(repository.path()).expect("clean diff");

        assert_eq!(response.sha, expected_sha);
        assert_eq!(response.diff, "");
    }

    #[test]
    fn renders_combined_tracked_untracked_deleted_and_symlink_changes() {
        let repository = repository();
        fs::write(repository.path().join("staged.txt"), "staged final\n")
            .expect("write staged change");
        git(repository.path(), &["add", "staged.txt"]);

        fs::write(
            repository.path().join("combined.txt"),
            "staged intermediate\n",
        )
        .expect("write intermediate change");
        git(repository.path(), &["add", "combined.txt"]);
        fs::write(repository.path().join("combined.txt"), "worktree final\n")
            .expect("write worktree change");

        fs::write(repository.path().join("unstaged.txt"), "unstaged final\n")
            .expect("write unstaged change");
        fs::remove_file(repository.path().join("deleted.txt")).expect("delete tracked file");
        fs::write(repository.path().join("untracked.txt"), "untracked final\n")
            .expect("write untracked file");
        fs::remove_file(repository.path().join("story-link")).expect("replace symlink");
        symlink("new-target", repository.path().join("story-link")).expect("new symlink");

        let response = git_diff_to_remote(repository.path()).expect("combined diff");
        let base = git(
            repository.path(),
            &["rev-parse", "refs/remotes/origin/main"],
        );
        let mut official = git_diff_output(
            repository.path(),
            &[
                "diff",
                "--no-color",
                "--binary",
                "--no-textconv",
                "--no-ext-diff",
                &base,
            ],
            0,
        );
        official.push_str(&git_diff_output(
            repository.path(),
            &[
                "diff",
                "--no-color",
                "--binary",
                "--no-index",
                "/dev/null",
                "untracked.txt",
            ],
            1,
        ));

        for path in [
            "staged.txt",
            "combined.txt",
            "unstaged.txt",
            "deleted.txt",
            "untracked.txt",
            "story-link",
        ] {
            assert!(
                response
                    .diff
                    .contains(&format!("diff --git a/{path} b/{path}")),
                "missing {path}:\n{}",
                response.diff
            );
        }
        assert!(response.diff.contains("-base staged.txt\n+staged final\n"));
        assert!(
            response
                .diff
                .contains("-base combined.txt\n+worktree final\n")
        );
        assert!(!response.diff.contains("staged intermediate"));
        assert!(
            response
                .diff
                .contains("-base unstaged.txt\n+unstaged final\n")
        );
        assert!(response.diff.contains("deleted file mode 100644"));
        assert!(response.diff.contains("new file mode 100644"));
        assert!(response.diff.contains("--- /dev/null\n+++ b/untracked.txt"));
        assert!(response.diff.contains("-old-target"));
        assert!(response.diff.contains("+new-target"));
        assert!(response.diff.contains("\\ No newline at end of file"));
        assert_eq!(response.diff, official);
    }

    #[test]
    fn selects_current_remote_branch_when_it_is_closer_than_default() {
        let repository = repository();
        git(repository.path(), &["checkout", "-b", "feature"]);
        fs::write(repository.path().join("feature.txt"), "remote feature\n")
            .expect("write remote feature");
        git(repository.path(), &["add", "feature.txt"]);
        git(repository.path(), &["commit", "-m", "remote feature"]);
        git(
            repository.path(),
            &[
                "update-ref",
                "refs/remotes/origin/feature",
                "refs/heads/feature",
            ],
        );
        let expected_sha = git(
            repository.path(),
            &["rev-parse", "refs/remotes/origin/feature"],
        );
        fs::write(repository.path().join("feature.txt"), "local feature\n")
            .expect("write local feature");
        git(repository.path(), &["commit", "-am", "local feature"]);

        let response = git_diff_to_remote(repository.path()).expect("feature diff");

        assert_eq!(response.sha, expected_sha);
        assert!(response.diff.contains("-remote feature\n+local feature\n"));
        assert!(!response.diff.contains("new file mode 100644"));
    }

    #[test]
    fn reports_non_repository_and_missing_remote_baseline() {
        let non_repository = tempfile::tempdir().expect("non repository");
        assert!(matches!(
            git_diff_to_remote(non_repository.path()),
            Err(GitDiffError::NotRepository)
        ));

        let no_remote = tempfile::tempdir().expect("repository without remote");
        git(no_remote.path(), &["init", "-b", "main"]);
        git(
            no_remote.path(),
            &["config", "user.email", "fixture@example.invalid"],
        );
        git(no_remote.path(), &["config", "user.name", "Fixture"]);
        fs::write(no_remote.path().join("only.txt"), "only\n").expect("write file");
        git(no_remote.path(), &["add", "."]);
        git(no_remote.path(), &["commit", "-m", "only"]);
        assert!(matches!(
            git_diff_to_remote(no_remote.path()),
            Err(GitDiffError::NoRemoteBase)
        ));
    }

    #[test]
    fn preserves_remote_to_worktree_semantics_across_index_only_states() {
        let repository = repository();
        fs::write(repository.path().join("ephemeral.txt"), "staged only\n")
            .expect("write staged addition");
        git(repository.path(), &["add", "ephemeral.txt"]);
        fs::remove_file(repository.path().join("ephemeral.txt")).expect("remove staged addition");

        fs::write(repository.path().join("story.txt"), "staged middle\n")
            .expect("write staged middle");
        git(repository.path(), &["add", "story.txt"]);
        fs::write(repository.path().join("story.txt"), "first\nsecond\n")
            .expect("restore worktree to base");

        let response = git_diff_to_remote(repository.path()).expect("index-only states");

        assert_eq!(response.diff, "");
    }

    #[test]
    fn index_removal_with_file_left_on_disk_is_delete_then_untracked_add() {
        let repository = repository();
        git(repository.path(), &["rm", "--cached", "story.txt"]);

        let response = git_diff_to_remote(repository.path()).expect("delete and re-add");

        assert_eq!(
            response
                .diff
                .matches("diff --git a/story.txt b/story.txt")
                .count(),
            2,
            "{}",
            response.diff
        );
        let deletion = response.diff.find("deleted file mode 100644").unwrap();
        let addition = response.diff.find("new file mode 100644").unwrap();
        assert!(deletion < addition);
    }

    #[test]
    fn ignored_untracked_files_are_scanned_but_omitted() {
        let repository = repository();
        fs::write(repository.path().join(".gitignore"), "*.ignored\n").expect("write ignore rule");
        git(repository.path(), &["add", ".gitignore"]);
        git(repository.path(), &["commit", "-m", "ignore rule"]);
        git(
            repository.path(),
            &["update-ref", "refs/remotes/origin/main", "refs/heads/main"],
        );
        fs::write(repository.path().join("private.ignored"), "ignored\n")
            .expect("write ignored file");

        let response = git_diff_to_remote(repository.path()).expect("ignored scan");

        assert_eq!(response.diff, "");
    }

    #[test]
    fn binary_patch_is_emitted_and_intent_to_add_remains_typed() {
        let binary = repository();
        fs::write(binary.path().join("story.txt"), b"first\0second").expect("write binary change");
        let response = git_diff_to_remote(binary.path()).expect("binary diff");
        assert!(response.diff.contains("GIT binary patch\nliteral 12\n"));

        let intent = repository();
        fs::write(intent.path().join("intent.txt"), "intent\n").expect("write intent file");
        git(intent.path(), &["add", "--intent-to-add", "intent.txt"]);
        assert!(matches!(
            git_diff_to_remote(intent.path()),
            Err(GitDiffError::IntentToAdd { .. })
        ));
    }

    #[test]
    fn conflicted_index_is_a_typed_error() {
        let repository = repository();
        git(repository.path(), &["checkout", "-b", "side"]);
        fs::write(repository.path().join("story.txt"), "side\n").expect("side change");
        git(repository.path(), &["commit", "-am", "side"]);
        git(repository.path(), &["checkout", "main"]);
        fs::write(repository.path().join("story.txt"), "main\n").expect("main change");
        git(repository.path(), &["commit", "-am", "main"]);
        let output = Command::new("git")
            .current_dir(repository.path())
            .args(["merge", "side"])
            .output()
            .expect("conflicting merge starts");
        assert!(!output.status.success(), "merge fixture must conflict");

        assert!(matches!(
            git_diff_to_remote(repository.path()),
            Err(GitDiffError::UnmergedIndex { .. })
        ));
    }

    #[test]
    fn rejects_a_tracked_path_reached_through_a_leading_symlink() {
        let repository = repository();
        let tracked_directory = repository.path().join("escape");
        fs::create_dir(&tracked_directory).expect("create tracked directory");
        fs::write(tracked_directory.join("tracked.txt"), "inside\n")
            .expect("write tracked nested file");
        git(repository.path(), &["add", "escape/tracked.txt"]);
        git(repository.path(), &["commit", "-m", "nested tracked file"]);
        git(
            repository.path(),
            &["update-ref", "refs/remotes/origin/main", "refs/heads/main"],
        );

        let outside = tempfile::tempdir().expect("outside directory");
        fs::write(outside.path().join("tracked.txt"), "outside\n").expect("write outside file");
        fs::remove_dir_all(&tracked_directory).expect("remove tracked directory");
        symlink(outside.path(), &tracked_directory).expect("replace directory with symlink");

        assert!(matches!(
            git_diff_to_remote(repository.path()),
            Err(GitDiffError::LeadingDirectorySymlink { path })
                if path == b"escape".as_slice()
        ));
    }

    #[test]
    fn unsupported_diff_configuration_is_a_typed_error() {
        for (key, value, expected_key) in [
            ("core.autocrlf", "true", "core.autocrlf"),
            ("core.eol", "lf", "core.eol"),
            (
                "core.attributesFile",
                ".git/global-attributes",
                "core.attributesFile",
            ),
            ("core.filemode", "false", "core.filemode"),
            ("core.symlinks", "false", "core.symlinks"),
            ("diff.algorithm", "patience", "diff.algorithm"),
            ("diff.context", "0", "diff.context"),
            ("diff.interHunkContext", "1", "diff.interHunkContext"),
            ("diff.renames", "false", "diff.renames"),
            ("core.abbrev", "12", "core.abbrev"),
            ("core.quotePath", "false", "core.quotePath"),
            ("diff.noPrefix", "true", "diff.noPrefix"),
            ("diff.srcPrefix", "old/", "diff.srcPrefix"),
            ("diff.dstPrefix", "new/", "diff.dstPrefix"),
            ("diff.orderFile", ".git/diff-order", "diff.orderFile"),
        ] {
            let repository = repository();
            git(repository.path(), &["config", key, value]);
            assert!(
                matches!(
                    git_diff_to_remote(repository.path()),
                    Err(GitDiffError::UnsupportedConfiguration { key })
                        if key == expected_key
                ),
                "{key} must be rejected"
            );
        }

        let filter = repository();
        git(filter.path(), &["config", "filter.fixture.clean", "cat"]);
        assert!(matches!(
            git_diff_to_remote(filter.path()),
            Err(GitDiffError::UnsupportedConfiguration { key: "filter.*" })
        ));

        let info_attributes = repository();
        fs::write(
            info_attributes.path().join(".git/info/attributes"),
            "*.txt text\n",
        )
        .expect("write info attributes");
        assert!(matches!(
            git_diff_to_remote(info_attributes.path()),
            Err(GitDiffError::UnsupportedConfiguration {
                key: ".git/info/attributes"
            })
        ));

        let worktree_attributes = repository();
        fs::write(
            worktree_attributes.path().join(".gitattributes"),
            "*.txt custom-attribute\n",
        )
        .expect("write worktree attributes");
        assert!(matches!(
            git_diff_to_remote(worktree_attributes.path()),
            Err(GitDiffError::UnsupportedAttributes { .. })
        ));
    }

    #[test]
    fn staged_rename_preserves_canonical_rename_metadata() {
        let repository = repository();
        git(repository.path(), &["mv", "story.txt", "renamed-story.txt"]);

        let response = git_diff_to_remote(repository.path()).expect("rename diff");
        assert!(response.diff.contains("similarity index 100%"));
        assert!(response.diff.contains("rename from story.txt"));
        assert!(response.diff.contains("rename to renamed-story.txt"));
        assert!(!response.diff.contains("deleted file mode"));
        assert!(!response.diff.contains("new file mode"));
    }

    #[test]
    fn embedded_repository_is_a_typed_phase_one_error() {
        let repository = repository();
        let embedded = repository.path().join("embedded");
        fs::create_dir(&embedded).expect("create embedded directory");
        git(&embedded, &["init", "-b", "main"]);

        assert!(matches!(
            git_diff_to_remote(repository.path()),
            Err(GitDiffError::NestedRepository { path })
                if path == b"embedded".as_slice()
        ));
    }

    #[test]
    fn printable_ascii_paths_match_git_without_unnecessary_c_quoting() {
        let repository = repository();
        let path = "punctuation @: [x].txt";
        fs::write(repository.path().join(path), "punctuation\n").expect("write unusual path");

        let response = git_diff_to_remote(repository.path()).expect("printable path diff");
        let official = git_diff_output(
            repository.path(),
            &[
                "diff",
                "--no-color",
                "--binary",
                "--no-index",
                "/dev/null",
                path,
            ],
            1,
        );

        assert_eq!(response.diff, official);
    }

    #[test]
    fn codex_core_dispatches_git_diff_to_remote_and_rejects_extra_params() {
        let repository = repository();
        fs::write(repository.path().join("story.txt"), "first\nchanged\n")
            .expect("write request fixture");
        let mut core = CodexCore::default();
        let request = serde_json::json!({
            "id": "diff-1",
            "method": "gitDiffToRemote",
            "params": {"cwd": repository.path()},
        });

        let response: serde_json::Value = serde_json::from_slice(
            &core
                .request(request.to_string().as_bytes())
                .expect("core diff"),
        )
        .expect("response JSON");

        assert_eq!(response["id"], "diff-1");
        assert_eq!(
            response["result"]["sha"],
            git(
                repository.path(),
                &["rev-parse", "refs/remotes/origin/main"]
            )
        );
        assert!(
            response["result"]["diff"]
                .as_str()
                .expect("diff string")
                .contains("-second\n+changed\n")
        );
        assert_eq!(
            core.request(
                serde_json::json!({
                    "method": "gitDiffToRemote",
                    "params": {"cwd": repository.path(), "extra": true},
                })
                .to_string()
                .as_bytes(),
            ),
            Err(CoreError::InvalidArgument)
        );
    }
}
