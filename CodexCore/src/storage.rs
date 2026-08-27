use super::CoreError;
use rusqlite::{Connection, params};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

const SCHEMA_VERSION: i64 = 3;
pub(crate) const PINNED_THREAD_SECTION_ID: &str = "01984de2-8f74-7c91-a3b2-5c5e937cf318";
pub(crate) const PINNED_THREAD_SECTION_NAME: &str = "Pinned";
const DEFAULT_THREAD_SECTION_LIMIT: usize = 25;
const MAX_THREAD_SECTION_LIMIT: usize = 100;

pub(crate) struct StoredBatch {
    pub(crate) first_sequence: u64,
    pub(crate) command: Vec<u8>,
    pub(crate) events: Vec<Vec<u8>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct EnrollmentKey {
    pub(crate) websocket_url: String,
    pub(crate) account_id: String,
    pub(crate) app_server_client_name: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct EnrollmentUpsert {
    pub(crate) key: EnrollmentKey,
    pub(crate) server_id: String,
    pub(crate) environment_id: String,
    pub(crate) server_name: String,
    pub(crate) updated_at: i64,
    pub(crate) remote_control_enabled: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct StoredEnrollment {
    pub(crate) key: EnrollmentKey,
    pub(crate) server_id: String,
    pub(crate) environment_id: String,
    pub(crate) server_name: String,
    pub(crate) updated_at: i64,
    pub(crate) remote_control_enabled: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
struct StoredThreadSection {
    id: String,
    name: String,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ThreadSectionListParams {
    #[serde(default)]
    cursor: Option<String>,
    #[serde(default)]
    limit: Option<u32>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ThreadSectionListResponse {
    data: Vec<StoredThreadSection>,
    next_cursor: Option<String>,
}

pub(crate) struct Storage {
    connection: Connection,
    snapshot_directory: PathBuf,
    pending_snapshot: Option<PathBuf>,
}

impl Storage {
    pub(crate) fn open(
        database_path: &Path,
        snapshot_directory: &Path,
    ) -> Result<(Self, Vec<StoredBatch>), CoreError> {
        require_absolute_file(database_path)?;
        require_absolute_directory(snapshot_directory)?;
        let parent = database_path.parent().ok_or(CoreError::InvalidArgument)?;
        fs::create_dir_all(parent).map_err(|_| CoreError::Storage)?;
        fs::create_dir_all(snapshot_directory).map_err(|_| CoreError::Storage)?;

        let existed = database_path
            .metadata()
            .map(|metadata| metadata.len() > 0)
            .unwrap_or(false);
        let initial = Connection::open(database_path).map_err(|_| CoreError::Storage)?;
        let old_version: i64 = initial
            .pragma_query_value(None, "user_version", |row| row.get(0))
            .map_err(|_| CoreError::Storage)?;
        if old_version > SCHEMA_VERSION {
            return Err(CoreError::Storage);
        }
        drop(initial);

        let created_snapshot = if existed && old_version < SCHEMA_VERSION {
            Some(create_snapshot(
                database_path,
                snapshot_directory,
                old_version,
            )?)
        } else {
            None
        };

        let connection = Connection::open(database_path).map_err(|_| CoreError::Storage)?;
        connection
            .execute_batch(
                "BEGIN IMMEDIATE;
                 CREATE TABLE IF NOT EXISTS metadata (
                   key TEXT PRIMARY KEY NOT NULL,
                   value TEXT NOT NULL
                 );
                 CREATE TABLE IF NOT EXISTS event_batches (
                   first_sequence INTEGER PRIMARY KEY NOT NULL,
                   event_count INTEGER NOT NULL,
                   command BLOB NOT NULL,
                   events_jsonl BLOB NOT NULL
                 );
                 CREATE TABLE IF NOT EXISTS remote_control_enrollments (
                   websocket_url TEXT NOT NULL,
                   account_id TEXT NOT NULL,
                   app_server_client_name TEXT NOT NULL DEFAULT '',
                   server_id TEXT NOT NULL,
                   environment_id TEXT NOT NULL,
                   server_name TEXT NOT NULL,
                   updated_at INTEGER NOT NULL,
                   remote_control_enabled INTEGER
                     CHECK(remote_control_enabled IN (0, 1)),
                   PRIMARY KEY (
                     websocket_url,
                     account_id,
                     app_server_client_name
                   )
                 ) WITHOUT ROWID;
                 CREATE TABLE IF NOT EXISTS thread_sections (
                   id TEXT PRIMARY KEY NOT NULL,
                   name TEXT NOT NULL
                 );
                 INSERT OR IGNORE INTO thread_sections(id, name)
                 VALUES ('01984de2-8f74-7c91-a3b2-5c5e937cf318', 'Pinned');
                 PRAGMA user_version = 3;
                 COMMIT;
                 PRAGMA journal_mode = WAL;
                 PRAGMA synchronous = FULL;",
            )
            .map_err(|_| CoreError::Storage)?;

        if let Some(snapshot) = &created_snapshot {
            let name = snapshot
                .file_name()
                .and_then(|value| value.to_str())
                .ok_or(CoreError::Storage)?;
            connection
                .execute(
                    "INSERT OR REPLACE INTO metadata(key, value)
                     VALUES('pending_snapshot', ?1)",
                    [name],
                )
                .map_err(|_| CoreError::Storage)?;
        }

        let pending_snapshot = match created_snapshot {
            Some(snapshot) => Some(snapshot),
            None => load_pending_snapshot(&connection, snapshot_directory)?,
        };
        let batches = load_batches(&connection)?;
        Ok((
            Self {
                connection,
                snapshot_directory: snapshot_directory.to_path_buf(),
                pending_snapshot,
            },
            batches,
        ))
    }

    pub(crate) fn restore(
        database_path: &Path,
        snapshot_directory: &Path,
        snapshot_name: &str,
    ) -> Result<(Self, Vec<StoredBatch>), CoreError> {
        require_absolute_file(database_path)?;
        require_absolute_directory(snapshot_directory)?;
        let snapshot = snapshot_directory.join(snapshot_name);
        require_owned_snapshot(snapshot_directory, &snapshot)?;
        if snapshot.file_name().and_then(|value| value.to_str()) != Some(snapshot_name)
            || !snapshot.is_file()
        {
            return Err(CoreError::InvalidArgument);
        }
        let parent = database_path.parent().ok_or(CoreError::InvalidArgument)?;
        fs::create_dir_all(parent).map_err(|_| CoreError::Storage)?;
        let temporary = parent.join(".CodexPad.restore.tmp");
        if temporary.exists() {
            fs::remove_file(&temporary).map_err(|_| CoreError::Storage)?;
        }
        fs::copy(&snapshot, &temporary).map_err(|_| CoreError::Storage)?;
        remove_sqlite_sidecar(database_path, "-wal")?;
        remove_sqlite_sidecar(database_path, "-shm")?;
        fs::rename(&temporary, database_path).map_err(|_| CoreError::Storage)?;
        Self::open(database_path, snapshot_directory)
    }

    pub(crate) fn append(
        &mut self,
        first_sequence: u64,
        command: &[u8],
        events: &[Vec<u8>],
    ) -> Result<(), CoreError> {
        let first_sequence = i64::try_from(first_sequence).map_err(|_| CoreError::Storage)?;
        let event_count = i64::try_from(events.len()).map_err(|_| CoreError::Storage)?;
        let events_jsonl = join_events(events);
        let transaction = self
            .connection
            .transaction()
            .map_err(|_| CoreError::Storage)?;
        transaction
            .execute(
                "INSERT INTO event_batches(
                   first_sequence, event_count, command, events_jsonl
                 ) VALUES(?1, ?2, ?3, ?4)",
                params![first_sequence, event_count, command, events_jsonl],
            )
            .map_err(|_| CoreError::Storage)?;
        transaction.commit().map_err(|_| CoreError::Storage)
    }

    pub(crate) fn confirm(&mut self) -> Result<(), CoreError> {
        let Some(snapshot) = self.pending_snapshot.take() else {
            return Ok(());
        };
        require_owned_snapshot(&self.snapshot_directory, &snapshot)?;
        if snapshot.exists() {
            fs::remove_file(&snapshot).map_err(|_| CoreError::Storage)?;
        }
        self.connection
            .execute("DELETE FROM metadata WHERE key = 'pending_snapshot'", [])
            .map_err(|_| CoreError::Storage)?;
        Ok(())
    }

    pub(crate) fn load_enrollment(
        &self,
        key: &EnrollmentKey,
    ) -> Result<Option<StoredEnrollment>, CoreError> {
        let result = self.connection.query_row(
            "SELECT server_id,
                    environment_id,
                    server_name,
                    updated_at,
                    remote_control_enabled
             FROM remote_control_enrollments
             WHERE websocket_url = ?1
               AND account_id = ?2
               AND app_server_client_name = ?3",
            params![
                key.websocket_url,
                key.account_id,
                key.app_server_client_name
            ],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, Option<i64>>(4)?,
                ))
            },
        );
        match result {
            Ok((server_id, environment_id, server_name, updated_at, remote_control_enabled)) => {
                Ok(Some(StoredEnrollment {
                    key: key.clone(),
                    server_id,
                    environment_id,
                    server_name,
                    updated_at,
                    remote_control_enabled: decode_enabled(remote_control_enabled)?,
                }))
            }
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(_) => Err(CoreError::Storage),
        }
    }

    pub(crate) fn upsert_enrollment(
        &mut self,
        enrollment: &EnrollmentUpsert,
    ) -> Result<(), CoreError> {
        self.connection
            .execute(
                "INSERT INTO remote_control_enrollments (
                   websocket_url,
                   account_id,
                   app_server_client_name,
                   server_id,
                   environment_id,
                   server_name,
                   updated_at,
                   remote_control_enabled
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                 ON CONFLICT (
                   websocket_url,
                   account_id,
                   app_server_client_name
                 ) DO UPDATE SET
                   server_id = excluded.server_id,
                   environment_id = excluded.environment_id,
                   server_name = excluded.server_name,
                   updated_at = excluded.updated_at",
                params![
                    enrollment.key.websocket_url,
                    enrollment.key.account_id,
                    enrollment.key.app_server_client_name,
                    enrollment.server_id,
                    enrollment.environment_id,
                    enrollment.server_name,
                    enrollment.updated_at,
                    enrollment.remote_control_enabled.map(i64::from),
                ],
            )
            .map(|_| ())
            .map_err(|_| CoreError::Storage)
    }

    pub(crate) fn set_enrollment_enabled(
        &mut self,
        key: &EnrollmentKey,
        enabled: bool,
        updated_at: i64,
    ) -> Result<bool, CoreError> {
        self.connection
            .execute(
                "UPDATE remote_control_enrollments
                 SET remote_control_enabled = ?1,
                     updated_at = ?2
                 WHERE websocket_url = ?3
                   AND account_id = ?4
                   AND app_server_client_name = ?5",
                params![
                    i64::from(enabled),
                    updated_at,
                    key.websocket_url,
                    key.account_id,
                    key.app_server_client_name,
                ],
            )
            .map(|affected| affected != 0)
            .map_err(|_| CoreError::Storage)
    }

    pub(crate) fn delete_enrollment(&mut self, key: &EnrollmentKey) -> Result<bool, CoreError> {
        self.connection
            .execute(
                "DELETE FROM remote_control_enrollments
                 WHERE websocket_url = ?1
                   AND account_id = ?2
                   AND app_server_client_name = ?3",
                params![
                    key.websocket_url,
                    key.account_id,
                    key.app_server_client_name
                ],
            )
            .map(|affected| affected != 0)
            .map_err(|_| CoreError::Storage)
    }

    pub(crate) fn thread_section_exists(&self, section_id: &str) -> Result<bool, CoreError> {
        self.connection
            .query_row(
                "SELECT EXISTS(
                   SELECT 1 FROM thread_sections WHERE id = ?1
                 )",
                [section_id],
                |row| row.get::<_, bool>(0),
            )
            .map_err(|_| CoreError::Storage)
    }

    pub(crate) fn list_thread_sections(
        &self,
        params: &serde_json::Value,
    ) -> Result<Vec<u8>, CoreError> {
        let params = if params.is_null() {
            ThreadSectionListParams::default()
        } else {
            serde_json::from_value(params.clone()).map_err(|_| CoreError::InvalidArgument)?
        };
        let limit = params
            .limit
            .map(|limit| limit as usize)
            .unwrap_or(DEFAULT_THREAD_SECTION_LIMIT)
            .clamp(1, MAX_THREAD_SECTION_LIMIT);
        let query_limit = i64::try_from(limit + 1).map_err(|_| CoreError::Storage)?;
        let mut statement = self
            .connection
            .prepare(
                "SELECT id, name
                 FROM thread_sections
                 WHERE (?1 IS NULL OR id > ?1)
                 ORDER BY id ASC
                 LIMIT ?2",
            )
            .map_err(|_| CoreError::Storage)?;
        let rows = statement
            .query_map(params![params.cursor, query_limit], |row| {
                Ok(StoredThreadSection {
                    id: row.get(0)?,
                    name: row.get(1)?,
                })
            })
            .map_err(|_| CoreError::Storage)?;
        let mut data = rows
            .collect::<Result<Vec<_>, _>>()
            .map_err(|_| CoreError::Storage)?;
        let has_more = data.len() > limit;
        data.truncate(limit);
        let next_cursor = has_more
            .then(|| data.last().map(|section| section.id.clone()))
            .flatten();
        serde_json::to_vec(&ThreadSectionListResponse { data, next_cursor })
            .map_err(|_| CoreError::InvalidJson)
    }
}

fn decode_enabled(value: Option<i64>) -> Result<Option<bool>, CoreError> {
    match value {
        None => Ok(None),
        Some(0) => Ok(Some(false)),
        Some(1) => Ok(Some(true)),
        Some(_) => Err(CoreError::Storage),
    }
}

fn load_pending_snapshot(
    connection: &Connection,
    snapshot_directory: &Path,
) -> Result<Option<PathBuf>, CoreError> {
    let result = connection.query_row(
        "SELECT value FROM metadata WHERE key = 'pending_snapshot'",
        [],
        |row| row.get::<_, String>(0),
    );
    match result {
        Ok(name) => {
            let snapshot = snapshot_directory.join(name);
            require_owned_snapshot(snapshot_directory, &snapshot)?;
            if !snapshot.is_file() {
                return Err(CoreError::Storage);
            }
            Ok(Some(snapshot))
        }
        Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
        Err(_) => Err(CoreError::Storage),
    }
}

fn load_batches(connection: &Connection) -> Result<Vec<StoredBatch>, CoreError> {
    let mut statement = connection
        .prepare(
            "SELECT first_sequence, event_count, command, events_jsonl
             FROM event_batches ORDER BY first_sequence",
        )
        .map_err(|_| CoreError::Storage)?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, Vec<u8>>(2)?,
                row.get::<_, Vec<u8>>(3)?,
            ))
        })
        .map_err(|_| CoreError::Storage)?;
    let mut batches = Vec::new();
    for row in rows {
        let (first_sequence, event_count, command, events_jsonl) =
            row.map_err(|_| CoreError::Storage)?;
        let first_sequence = u64::try_from(first_sequence).map_err(|_| CoreError::Storage)?;
        let event_count = usize::try_from(event_count).map_err(|_| CoreError::Storage)?;
        let events = split_events(&events_jsonl)?;
        if events.is_empty() || events.len() != event_count {
            return Err(CoreError::Storage);
        }
        batches.push(StoredBatch {
            first_sequence,
            command,
            events,
        });
    }
    Ok(batches)
}

fn join_events(events: &[Vec<u8>]) -> Vec<u8> {
    let capacity = events.iter().map(Vec::len).sum::<usize>() + events.len();
    let mut output = Vec::with_capacity(capacity);
    for (index, event) in events.iter().enumerate() {
        if index > 0 {
            output.push(b'\n');
        }
        output.extend_from_slice(event);
    }
    output
}

fn split_events(events: &[u8]) -> Result<Vec<Vec<u8>>, CoreError> {
    if events.is_empty() {
        return Err(CoreError::Storage);
    }
    events
        .split(|byte| *byte == b'\n')
        .map(|event| {
            serde_json::from_slice::<serde_json::Value>(event)
                .map(|_| event.to_vec())
                .map_err(|_| CoreError::Storage)
        })
        .collect()
}

fn create_snapshot(
    database_path: &Path,
    snapshot_directory: &Path,
    old_version: i64,
) -> Result<PathBuf, CoreError> {
    let name = format!("schema-{old_version}-to-{SCHEMA_VERSION}.sqlite");
    let destination = snapshot_directory.join(name);
    require_owned_snapshot(snapshot_directory, &destination)?;
    if destination.exists() {
        return Ok(destination);
    }
    let temporary = snapshot_directory.join(format!(
        ".{}.tmp",
        destination.file_name().unwrap().to_string_lossy()
    ));
    fs::copy(database_path, &temporary).map_err(|_| CoreError::Storage)?;
    fs::rename(&temporary, &destination).map_err(|_| CoreError::Storage)?;
    Ok(destination)
}

fn require_absolute_file(path: &Path) -> Result<(), CoreError> {
    if !path.is_absolute() || path.file_name().is_none() {
        return Err(CoreError::InvalidArgument);
    }
    Ok(())
}

fn require_absolute_directory(path: &Path) -> Result<(), CoreError> {
    if !path.is_absolute() {
        return Err(CoreError::InvalidArgument);
    }
    Ok(())
}

fn require_owned_snapshot(directory: &Path, snapshot: &Path) -> Result<(), CoreError> {
    if snapshot.parent() != Some(directory)
        || snapshot.extension().and_then(|value| value.to_str()) != Some("sqlite")
    {
        return Err(CoreError::InvalidArgument);
    }
    Ok(())
}

fn remove_sqlite_sidecar(database_path: &Path, suffix: &str) -> Result<(), CoreError> {
    let sidecar = PathBuf::from(format!("{}{suffix}", database_path.display()));
    if sidecar.exists() {
        fs::remove_file(sidecar).map_err(|_| CoreError::Storage)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn schema_v1_migrates_to_enrollment_and_thread_section_storage() {
        let temporary = tempfile::tempdir().unwrap();
        let database_path = temporary.path().join("state.sqlite");
        let snapshot_directory = temporary.path().join("snapshots");
        let connection = Connection::open(&database_path).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE metadata (
                   key TEXT PRIMARY KEY NOT NULL,
                   value TEXT NOT NULL
                 );
                 CREATE TABLE event_batches (
                   first_sequence INTEGER PRIMARY KEY NOT NULL,
                   event_count INTEGER NOT NULL,
                   command BLOB NOT NULL,
                   events_jsonl BLOB NOT NULL
                 );
                 PRAGMA user_version = 1;",
            )
            .unwrap();
        drop(connection);

        let (_storage, batches) = Storage::open(&database_path, &snapshot_directory).unwrap();

        assert!(batches.is_empty());
        let connection = Connection::open(&database_path).unwrap();
        let version: i64 = connection
            .pragma_query_value(None, "user_version", |row| row.get(0))
            .unwrap();
        assert_eq!(version, 3);
        let columns = connection
            .prepare("PRAGMA table_info(remote_control_enrollments)")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        assert_eq!(
            columns,
            [
                "websocket_url",
                "account_id",
                "app_server_client_name",
                "server_id",
                "environment_id",
                "server_name",
                "updated_at",
                "remote_control_enabled",
            ]
        );
        assert!(!columns.iter().any(|column| matches!(
            column.as_str(),
            "access_token"
                | "remote_control_token"
                | "expires_at"
                | "refresh_token"
                | "cursor"
                | "tasks"
        )));
        let pinned: (String, String) = connection
            .query_row("SELECT id, name FROM thread_sections", [], |row| {
                Ok((row.get(0)?, row.get(1)?))
            })
            .unwrap();
        assert_eq!(
            pinned,
            (
                PINNED_THREAD_SECTION_ID.to_owned(),
                PINNED_THREAD_SECTION_NAME.to_owned()
            )
        );
    }

    #[test]
    fn thread_sections_page_by_stable_id_and_preserve_renames() {
        let temporary = tempfile::tempdir().unwrap();
        let database_path = temporary.path().join("state.sqlite");
        let snapshot_directory = temporary.path().join("snapshots");
        let (storage, _) = Storage::open(&database_path, &snapshot_directory).unwrap();
        storage
            .connection
            .execute(
                "INSERT INTO thread_sections(id, name) VALUES(?1, ?2)",
                params!["01984de2-8f74-7c91-a3b2-5c5e937cf317", "Before pinned"],
            )
            .unwrap();

        let first: serde_json::Value = serde_json::from_slice(
            &storage
                .list_thread_sections(&serde_json::json!({"limit": 0}))
                .unwrap(),
        )
        .unwrap();
        assert_eq!(first["data"][0]["name"], "Before pinned");
        let first_cursor = first["nextCursor"].as_str().unwrap();

        let second: serde_json::Value = serde_json::from_slice(
            &storage
                .list_thread_sections(&serde_json::json!({
                    "cursor": first_cursor,
                    "limit": 1
                }))
                .unwrap(),
        )
        .unwrap();
        assert_eq!(second["data"][0]["id"], PINNED_THREAD_SECTION_ID);
        assert!(second["nextCursor"].is_null());

        storage
            .connection
            .execute(
                "UPDATE thread_sections SET name = 'Favorites' WHERE id = ?1",
                [PINNED_THREAD_SECTION_ID],
            )
            .unwrap();
        drop(storage);

        let (reopened, _) = Storage::open(&database_path, &snapshot_directory).unwrap();
        let sections: serde_json::Value = serde_json::from_slice(
            &reopened
                .list_thread_sections(&serde_json::Value::Null)
                .unwrap(),
        )
        .unwrap();
        assert_eq!(sections["data"][1]["name"], "Favorites");
    }

    #[test]
    fn enrollment_upsert_starts_unset_and_preserves_enabled_while_refreshing_fields() {
        let temporary = tempfile::tempdir().unwrap();
        let database_path = temporary.path().join("state.sqlite");
        let snapshot_directory = temporary.path().join("snapshots");
        let (mut storage, _) = Storage::open(&database_path, &snapshot_directory).unwrap();
        let key = enrollment_key("wss://one.test/ws", "account-1", "client-1");

        storage
            .upsert_enrollment(&EnrollmentUpsert {
                key: key.clone(),
                server_id: "server-old".to_string(),
                environment_id: "environment-old".to_string(),
                server_name: "Codex old".to_string(),
                updated_at: 10,
                remote_control_enabled: None,
            })
            .unwrap();
        assert_eq!(
            storage.load_enrollment(&key).unwrap(),
            Some(StoredEnrollment {
                key: key.clone(),
                server_id: "server-old".to_string(),
                environment_id: "environment-old".to_string(),
                server_name: "Codex old".to_string(),
                updated_at: 10,
                remote_control_enabled: None,
            })
        );

        assert!(storage.set_enrollment_enabled(&key, true, 20).unwrap());
        storage
            .upsert_enrollment(&EnrollmentUpsert {
                key: key.clone(),
                server_id: "server-new".to_string(),
                environment_id: "environment-new".to_string(),
                server_name: "Codex new".to_string(),
                updated_at: 30,
                remote_control_enabled: None,
            })
            .unwrap();

        assert_eq!(
            storage.load_enrollment(&key).unwrap(),
            Some(StoredEnrollment {
                key,
                server_id: "server-new".to_string(),
                environment_id: "environment-new".to_string(),
                server_name: "Codex new".to_string(),
                updated_at: 30,
                remote_control_enabled: Some(true),
            })
        );
    }

    #[test]
    fn enrollment_upsert_inserts_false_and_conflict_does_not_replace_it() {
        let temporary = tempfile::tempdir().unwrap();
        let database_path = temporary.path().join("state.sqlite");
        let snapshot_directory = temporary.path().join("snapshots");
        let (mut storage, _) = Storage::open(&database_path, &snapshot_directory).unwrap();
        let key = enrollment_key("wss://one.test/ws", "account-1", "client-1");

        storage
            .upsert_enrollment(&EnrollmentUpsert {
                key: key.clone(),
                server_id: "server-old".to_string(),
                environment_id: "environment-old".to_string(),
                server_name: "Codex old".to_string(),
                updated_at: 10,
                remote_control_enabled: Some(false),
            })
            .unwrap();
        assert_eq!(
            storage
                .load_enrollment(&key)
                .unwrap()
                .unwrap()
                .remote_control_enabled,
            Some(false)
        );

        storage
            .upsert_enrollment(&EnrollmentUpsert {
                key: key.clone(),
                server_id: "server-new".to_string(),
                environment_id: "environment-new".to_string(),
                server_name: "Codex new".to_string(),
                updated_at: 20,
                remote_control_enabled: Some(true),
            })
            .unwrap();

        assert_eq!(
            storage.load_enrollment(&key).unwrap(),
            Some(StoredEnrollment {
                key,
                server_id: "server-new".to_string(),
                environment_id: "environment-new".to_string(),
                server_name: "Codex new".to_string(),
                updated_at: 20,
                remote_control_enabled: Some(false),
            })
        );
    }

    #[test]
    fn enrollment_mutations_match_all_three_key_fields() {
        let temporary = tempfile::tempdir().unwrap();
        let database_path = temporary.path().join("state.sqlite");
        let snapshot_directory = temporary.path().join("snapshots");
        let (mut storage, _) = Storage::open(&database_path, &snapshot_directory).unwrap();
        let keys = [
            enrollment_key("wss://one.test/ws", "account-1", ""),
            enrollment_key("wss://two.test/ws", "account-1", ""),
            enrollment_key("wss://one.test/ws", "account-2", ""),
            enrollment_key("wss://one.test/ws", "account-1", "client-1"),
        ];
        for (index, key) in keys.iter().enumerate() {
            storage
                .upsert_enrollment(&EnrollmentUpsert {
                    key: key.clone(),
                    server_id: format!("server-{index}"),
                    environment_id: format!("environment-{index}"),
                    server_name: format!("Codex {index}"),
                    updated_at: i64::try_from(index).unwrap(),
                    remote_control_enabled: None,
                })
                .unwrap();
        }

        assert!(storage.set_enrollment_enabled(&keys[0], false, 40).unwrap());
        assert!(storage.delete_enrollment(&keys[3]).unwrap());
        assert!(!storage.set_enrollment_enabled(&keys[3], true, 50).unwrap());
        assert!(!storage.delete_enrollment(&keys[3]).unwrap());

        let first = storage.load_enrollment(&keys[0]).unwrap().unwrap();
        assert_eq!(first.remote_control_enabled, Some(false));
        assert_eq!(first.updated_at, 40);
        assert!(
            storage
                .load_enrollment(&keys[1])
                .unwrap()
                .unwrap()
                .remote_control_enabled
                .is_none()
        );
        assert!(
            storage
                .load_enrollment(&keys[2])
                .unwrap()
                .unwrap()
                .remote_control_enabled
                .is_none()
        );
        assert_eq!(storage.load_enrollment(&keys[3]).unwrap(), None);
    }

    fn enrollment_key(
        websocket_url: &str,
        account_id: &str,
        app_server_client_name: &str,
    ) -> EnrollmentKey {
        EnrollmentKey {
            websocket_url: websocket_url.to_string(),
            account_id: account_id.to_string(),
            app_server_client_name: app_server_client_name.to_string(),
        }
    }
}
