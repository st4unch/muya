// Created by Claude — Classification: INTERNAL
//
// Schedules (docs/prd-schedules.md): the logic — store, timer, lock hand-over, runner and the
// agent API — lives in `muya_core::schedules` (native rewrite, PRD AC22, strangler). This file
// keeps the Tauri command shims, the window's timer start and the old import paths.

pub use muya_core::schedules::*;

use tauri::{AppHandle, Emitter, Manager, State};

const CHANGED_EVENT: &str = "schedules-changed";

#[tauri::command]
pub async fn schedules_list(state: State<'_, ScheduleState>) -> Result<ListResult, String> {
    let state = state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || state.list())
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn schedule_save(
    state: State<'_, ScheduleState>,
    job: JobInput,
) -> Result<Job, String> {
    let state = state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || state.save(job))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn schedule_set_enabled(
    state: State<'_, ScheduleState>,
    id: String,
    enabled: bool,
) -> Result<(), String> {
    let state = state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || state.set_job_enabled(&id, enabled))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn schedule_delete(
    state: State<'_, ScheduleState>,
    id: String,
) -> Result<(), String> {
    let state = state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || state.delete_job(&id))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
pub fn schedule_run_now(state: State<'_, ScheduleState>, id: String) -> Result<(), String> {
    state.run_now(&id)
}

/// Runs of one job, newest first.
#[tauri::command]
pub async fn schedule_runs(
    state: State<'_, ScheduleState>,
    id: String,
) -> Result<Vec<Run>, String> {
    let state = state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || state.runs(&id))
        .await
        .map_err(|e| e.to_string())?
}

/// The window's timer. Started once from setup.
pub fn start(app: &AppHandle) {
    let state = app.state::<ScheduleState>().inner().clone();
    let h = app.clone();
    state.set_sink(move || {
        let _ = h.emit(CHANGED_EVENT, ());
    });
    state.set_spawner(|f| {
        tauri::async_runtime::spawn(f);
    });
    tauri::async_runtime::spawn(run_timer(state));
}

/// One agent operation (muya-mcp tools via broker.rs).
pub fn agent_op(
    app: &AppHandle,
    op: &str,
    key: Option<&str>,
    fields: Option<&serde_json::Value>,
    enabled: Option<bool>,
    limit: Option<usize>,
) -> Result<serde_json::Value, String> {
    app.state::<ScheduleState>()
        .inner()
        .clone()
        .agent_op(op, key, fields, enabled, limit)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{DateTime, Local, NaiveDate, TimeZone};
    use std::collections::{HashMap, HashSet};
    use std::fs;
    use std::path::Path;

    #[test]
    fn agent_fields_merge_onto_the_job_and_names_resolve() {
        let home = tempfile::tempdir().unwrap();
        let work = tempfile::tempdir().unwrap();
        let st = ScheduleState::at(home.path());
        let mut g = st.inner.lock().unwrap();
        let folder = work.path().to_str().unwrap();
        let fields = serde_json::json!({ "name": "Audit", "prompt": "audit", "folder": folder, "schedule": { "kind": "interval", "minutes": 30 } });
        let j = upsert(&mut g, input_from(None, &fields).unwrap()).unwrap();
        assert!(
            j.enabled && j.bypass && j.timeout_min == 30,
            "page defaults for a new job"
        );
        assert_eq!(
            resolve(&g, "audit").unwrap(),
            j.id,
            "names match case-insensitively"
        );
        assert_eq!(resolve(&g, &j.id).unwrap(), j.id);
        assert!(resolve(&g, "nope").is_err());

        let patched = input_from(
            Some(&j),
            &serde_json::json!({ "timeoutMin": 5, "bypass": false }),
        )
        .unwrap();
        assert_eq!(
            (patched.name.as_str(), patched.timeout_min, patched.bypass),
            ("Audit", 5, false)
        );
        assert_eq!(
            patched.schedule,
            Schedule::Interval { minutes: 30 },
            "fields not given are kept"
        );
        assert!(input_from(None, &serde_json::json!({ "name": "x" }))
            .unwrap_err()
            .contains("prompt"));

        upsert(&mut g, input_from(None, &fields).unwrap()).unwrap();
        assert!(
            resolve(&g, "Audit").unwrap_err().contains("use the id"),
            "duplicate names must be addressed by id"
        );

        let long = Run {
            job_id: j.id.clone(),
            started: 1,
            ended: 2,
            status: RunStatus::Success,
            exit_code: Some(0),
            cost_usd: None,
            trigger: "manual".into(),
            output: "é".repeat(AGENT_OUTPUT_CAP),
        };
        assert!(agent_run(&long)["output"]
            .as_str()
            .unwrap()
            .ends_with("Schedules page)"));
    }

    fn at(y: i32, m: u32, d: u32, h: u32, min: u32) -> DateTime<Local> {
        Local
            .from_local_datetime(
                &NaiveDate::from_ymd_opt(y, m, d)
                    .unwrap()
                    .and_hms_opt(h, min, 0)
                    .unwrap(),
            )
            .earliest()
            .unwrap()
    }

    #[test]
    fn interval_adds_minutes_and_rejects_short_ones() {
        let t = at(2026, 1, 5, 10, 0);
        assert_eq!(
            next_after(&Schedule::Interval { minutes: 30 }, t),
            Some(at(2026, 1, 5, 10, 30))
        );
        assert_eq!(next_after(&Schedule::Interval { minutes: 4 }, t), None);
    }

    #[test]
    fn daily_is_today_if_still_ahead_else_tomorrow() {
        let s = Schedule::Daily {
            time: "09:30".into(),
                extra_times: vec![],
        };
        assert_eq!(
            next_after(&s, at(2026, 1, 5, 8, 0)),
            Some(at(2026, 1, 5, 9, 30))
        );
        assert_eq!(
            next_after(&s, at(2026, 1, 5, 9, 30)),
            Some(at(2026, 1, 6, 9, 30))
        );
        assert_eq!(
            next_after(&s, at(2026, 12, 31, 23, 0)),
            Some(at(2027, 1, 1, 9, 30))
        );
        assert_eq!(
            next_after(
                &Schedule::Daily {
                    time: "25:00".into(),
                extra_times: vec![],
                },
                at(2026, 1, 5, 8, 0)
            ),
            None
        );
    }

    #[test]
    fn several_times_a_day_pick_the_earliest_ahead() {
        let s = Schedule::Daily {
            time: "09:00".into(),
            extra_times: vec!["19:00".into(), "13:30".into(), "09:00".into()],
        };
        assert_eq!(next_after(&s, at(2026, 1, 5, 8, 0)), Some(at(2026, 1, 5, 9, 0)));
        assert_eq!(next_after(&s, at(2026, 1, 5, 9, 0)), Some(at(2026, 1, 5, 13, 30)));
        assert_eq!(next_after(&s, at(2026, 1, 5, 14, 0)), Some(at(2026, 1, 5, 19, 0)));
        assert_eq!(next_after(&s, at(2026, 1, 5, 19, 0)), Some(at(2026, 1, 6, 9, 0)));
        // weekly: Mon + Wed, 08:00 and 20:00 (2026-01-05 is a Monday)
        let w = Schedule::Weekly {
            days: vec![0, 2],
            time: "20:00".into(),
            extra_times: vec!["08:00".into()],
        };
        assert_eq!(next_after(&w, at(2026, 1, 5, 9, 0)), Some(at(2026, 1, 5, 20, 0)));
        assert_eq!(next_after(&w, at(2026, 1, 5, 21, 0)), Some(at(2026, 1, 7, 8, 0)));
        // a bad extra time or too many times → invalid
        let bad = Schedule::Daily { time: "09:00".into(), extra_times: vec!["7pm".into()] };
        assert_eq!(next_after(&bad, at(2026, 1, 5, 8, 0)), None);
        let many = Schedule::Daily {
            time: "01:00".into(),
            extra_times: (2..=7).map(|h| format!("{h:02}:00")).collect(),
        };
        assert_eq!(next_after(&many, at(2026, 1, 5, 0, 0)), None);
    }

    #[test]
    fn validate_explains_bad_or_too_many_times() {
        let input = |extra: serde_json::Value| {
            input_from(None, &serde_json::json!({ "name": "a", "prompt": "b", "folder": "/tmp",
                "schedule": { "kind": "daily", "time": "09:00", "extraTimes": extra } }))
            .unwrap()
        };
        assert!(validate(&input(serde_json::json!(["19:00"]))).is_ok());
        assert_eq!(validate(&input(serde_json::json!(["7pm"]))).unwrap_err(), "Use times like 09:30.");
        let six: Vec<String> = (10..16).map(|h| format!("{h}:00")).collect();
        assert_eq!(validate(&input(serde_json::json!(six))).unwrap_err(), "At most 6 times a day.");
    }

    #[test]
    fn extra_times_are_optional_and_omitted_when_empty() {
        let old: Schedule = serde_json::from_str(r#"{"kind":"daily","time":"09:00"}"#).unwrap();
        assert_eq!(old, Schedule::Daily { time: "09:00".into(), extra_times: vec![] });
        assert_eq!(serde_json::to_string(&old).unwrap(), r#"{"kind":"daily","time":"09:00"}"#);
        let two: Schedule =
            serde_json::from_str(r#"{"kind":"weekly","days":[1],"time":"09:00","extraTimes":["19:00"]}"#).unwrap();
        assert!(serde_json::to_string(&two).unwrap().contains(r#""extraTimes":["19:00"]"#));
    }

    #[test]
    fn weekly_finds_the_next_chosen_weekday() {
        // 2026-01-05 is a Monday.
        let s = Schedule::Weekly {
            days: vec![2, 4],
            time: "18:00".into(),
                extra_times: vec![],
        }; // Wed, Fri
        assert_eq!(
            next_after(&s, at(2026, 1, 5, 12, 0)),
            Some(at(2026, 1, 7, 18, 0))
        );
        assert_eq!(
            next_after(&s, at(2026, 1, 9, 18, 0)),
            Some(at(2026, 1, 14, 18, 0))
        );
        let mon = Schedule::Weekly {
            days: vec![0],
            time: "08:00".into(),
                extra_times: vec![],
        };
        assert_eq!(
            next_after(&mon, at(2026, 1, 5, 9, 0)),
            Some(at(2026, 1, 12, 8, 0))
        );
        assert_eq!(
            next_after(
                &Schedule::Weekly {
                    days: vec![],
                    time: "08:00".into(),
                extra_times: vec![],
                },
                at(2026, 1, 5, 9, 0)
            ),
            None
        );
        assert_eq!(
            next_after(
                &Schedule::Weekly {
                    days: vec![7],
                    time: "08:00".into(),
                extra_times: vec![],
                },
                at(2026, 1, 5, 9, 0)
            ),
            None
        );
    }

    #[test]
    fn prompt_is_one_argv_element_after_double_dash() {
        let a = claude_args("-rf; rm -rf ~ && echo $(whoami)", true, false);
        assert_eq!(a[a.len() - 2], "--");
        assert_eq!(a.last().unwrap(), "-rf; rm -rf ~ && echo $(whoami)");
        assert!(a.contains(&"--dangerously-skip-permissions".to_string()));
        let safe = claude_args("x", false, false);
        assert!(safe
            .windows(2)
            .any(|w| w[0] == "--permission-mode" && w[1] == "acceptEdits"));
        assert!(!safe.contains(&"--dangerously-skip-permissions".to_string()));
        assert!(!safe.contains(&"--chrome".to_string()));
        let c = claude_args("x", true, true);
        assert!(c.contains(&"--chrome".to_string()));
        assert_eq!(c[c.len() - 2], "--", "the prompt still comes last");
    }

    #[test]
    fn chrome_defaults_on_for_new_and_older_jobs() {
        let old = r#"{"id":"s1","name":"n","prompt":"p","folder":"/tmp","schedule":{"kind":"daily","time":"09:00"},"enabled":true,"timeoutMin":30,"bypass":true,"created":1,"updated":1}"#;
        assert!(serde_json::from_str::<Job>(old).unwrap().chrome, "a 4.1.0 job gets the browser");
        let off = input_from(None, &serde_json::json!({ "name": "a", "prompt": "b", "folder": "/tmp", "schedule": { "kind": "daily", "time": "09:00" }, "chrome": false })).unwrap();
        assert!(!off.chrome);
        let new = input_from(None, &serde_json::json!({ "name": "a", "prompt": "b", "folder": "/tmp", "schedule": { "kind": "daily", "time": "09:00" } })).unwrap();
        assert!(new.chrome);
    }

    #[test]
    fn classify_reads_claude_json() {
        let ok = r#"{"type":"result","is_error":false,"result":"done","total_cost_usd":0.12}"#;
        let (st, cost, text) = classify(Some(0), ok, "");
        assert_eq!(
            (st, cost, text.as_str()),
            (RunStatus::Success, Some(0.12), "done")
        );
        let bad = r#"{"type":"result","is_error":true,"result":"limit"}"#;
        assert_eq!(classify(Some(0), bad, "").0, RunStatus::Failed);
        let (st, _, text) = classify(Some(1), "", "boom");
        assert_eq!(st, RunStatus::Failed);
        assert_eq!(text, "boom");
        assert_eq!(classify(Some(0), "not json", "").0, RunStatus::Failed);
        let big = "x".repeat(MAX_OUTPUT + 10);
        assert!(classify(Some(1), &big, "")
            .2
            .ends_with("(output truncated)"));
    }

    fn input(folder: &str) -> JobInput {
        JobInput {
            id: None,
            name: "Daily report".into(),
            prompt: "summarize".into(),
            folder: folder.into(),
            schedule: Schedule::Daily {
                time: "09:00".into(),
                extra_times: vec![],
            },
            enabled: true,
            timeout_min: 30,
            bypass: true,
            chrome: true,
        }
    }

    #[test]
    fn validate_rejects_bad_input() {
        let dir = tempfile::tempdir().unwrap();
        let d = dir.path().to_str().unwrap();
        assert!(validate(&input(d)).is_ok());
        assert!(validate(&input("relative/dir")).is_err());
        assert!(validate(&input("/definitely/not/here")).is_err());
        assert!(validate(&JobInput {
            prompt: "  ".into(),
            ..input(d)
        })
        .is_err());
        assert!(validate(&JobInput {
            name: "".into(),
            ..input(d)
        })
        .is_err());
        assert!(validate(&JobInput {
            timeout_min: 0,
            ..input(d)
        })
        .is_err());
        assert!(validate(&JobInput {
            schedule: Schedule::Interval { minutes: 1 },
            ..input(d)
        })
        .is_err());
    }

    #[test]
    fn jobs_persist_edit_toggle_and_delete_with_history() {
        let home = tempfile::tempdir().unwrap();
        let work = tempfile::tempdir().unwrap();
        let st = ScheduleState::at(home.path());
        let mut g = st.inner.lock().unwrap();
        assert!(g.active);
        let j = upsert(&mut g, input(work.path().to_str().unwrap())).unwrap();
        assert!(g.due.contains_key(&j.id));
        let edited = upsert(
            &mut g,
            JobInput {
                id: Some(j.id.clone()),
                name: "Renamed".into(),
                ..input(work.path().to_str().unwrap())
            },
        )
        .unwrap();
        assert_eq!(edited.created, j.created);
        set_enabled(&mut g, &j.id, false).unwrap();
        let paths = g.paths.clone();
        drop(g);

        // Reloaded from disk.
        let jobs = load_jobs(&paths);
        assert_eq!(jobs.len(), 1);
        assert_eq!(jobs[0].name, "Renamed");
        assert!(!jobs[0].enabled);

        for i in 0..(MAX_RUNS_KEPT + 5) {
            let status = if i % 2 == 0 {
                RunStatus::Success
            } else {
                RunStatus::Failed
            };
            append_run(
                &paths,
                &Run {
                    job_id: j.id.clone(),
                    started: i as i64,
                    ended: i as i64 + 1,
                    status,
                    exit_code: Some(0),
                    cost_usd: None,
                    trigger: "manual".into(),
                    output: "o".into(),
                },
            )
            .unwrap();
        }
        let runs = read_runs(&paths, &j.id);
        assert_eq!(runs.len(), MAX_RUNS_KEPT);
        assert_eq!(runs[0].started, 5, "oldest runs are dropped");
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            fs::metadata(paths.runs_file(&j.id))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        assert_eq!(
            fs::metadata(&paths.runs).unwrap().permissions().mode() & 0o777,
            0o700
        );

        let st2 = ScheduleState::at(home.path());
        assert!(
            !st2.inner.lock().unwrap().active,
            "a second instance does not fire timers"
        );
        let v = view(&st.inner.lock().unwrap());
        assert_eq!((v[0].runs, v[0].ok, v[0].failed), (100, 50, 50));
        assert_eq!(v[0].next_run, None, "disabled job has no next run");

        delete(&mut st.inner.lock().unwrap(), &j.id).unwrap();
        assert!(load_jobs(&paths).is_empty());
        assert!(!paths.runs_file(&j.id).exists());
    }

    fn job_in(st: &ScheduleState, folder: &Path) -> Job {
        upsert(&mut st.inner.lock().unwrap(), input(folder.to_str().unwrap())).unwrap()
    }

    #[test]
    fn a_waiting_process_takes_the_lock_once_it_is_free() {
        let home = tempfile::tempdir().unwrap();
        let first = ScheduleState::at(home.path());
        let second = ScheduleState::at(home.path());
        assert!(first.inner.lock().unwrap().active);
        second.tick(Local::now());
        assert!(!second.inner.lock().unwrap().active, "lock still held");
        drop(first);
        let (_, refresh) = second.tick(Local::now());
        assert!(second.inner.lock().unwrap().active && refresh, "taken on the next tick");
    }

    #[test]
    fn the_window_hands_the_timers_to_the_service_and_takes_them_back() {
        let home = tempfile::tempdir().unwrap();
        let app = ScheduleState::at(home.path());
        assert!(app.inner.lock().unwrap().active);
        let service = ScheduleState::at_role(home.path(), Role::Service);
        assert!(!service.inner.lock().unwrap().active, "the window got there first");

        service.tick(Local::now()); // writes the heartbeat
        let paths = Paths::under(home.path());
        assert!(heartbeat_at(&paths, now_ms()).is_some());
        app.tick(Local::now());
        assert!(!app.inner.lock().unwrap().active, "the window yields to a live service");
        service.tick(Local::now());
        assert!(service.inner.lock().unwrap().active, "the service takes the free lock");

        let _ = fs::remove_file(&paths.heartbeat);
        app.tick(Local::now());
        assert!(!app.inner.lock().unwrap().active, "the service still holds the lock");
        drop(service);
        app.tick(Local::now());
        assert!(app.inner.lock().unwrap().active, "service gone: the window runs the timers again");

        // A stale heartbeat does not count.
        write_json(
            &paths.heartbeat,
            &Heartbeat { pid: 1, version: "x".into(), ts: now_ms() - HEARTBEAT_FRESH_MS - 1 },
        );
        app.tick(Local::now());
        assert!(app.inner.lock().unwrap().active);
    }

    #[test]
    fn the_active_process_picks_up_jobs_written_by_another() {
        let home = tempfile::tempdir().unwrap();
        let work = tempfile::tempdir().unwrap();
        let active = ScheduleState::at(home.path());
        let passive = ScheduleState::at(home.path());
        let j = job_in(&passive, work.path());
        let (_, refresh) = active.tick(Local::now());
        assert!(refresh);
        {
            let g = active.inner.lock().unwrap();
            assert!(g.jobs.iter().any(|x| x.id == j.id));
            assert!(g.due.contains_key(&j.id), "a new job gets its next run");
        }
        // And an edit made on the active side is not lost by the passive one's next write.
        set_enabled(&mut active.inner.lock().unwrap(), &j.id, false).unwrap();
        let other = job_in(&passive, work.path());
        let jobs = load_jobs(&Paths::under(home.path()));
        assert_eq!(jobs.len(), 2);
        assert!(!jobs.iter().find(|x| x.id == j.id).unwrap().enabled);
        assert!(jobs.iter().any(|x| x.id == other.id));
    }

    #[test]
    fn run_now_from_a_passive_process_goes_through_a_request_file() {
        let home = tempfile::tempdir().unwrap();
        let work = tempfile::tempdir().unwrap();
        let active = ScheduleState::at(home.path());
        let passive = ScheduleState::at(home.path());
        let j = job_in(&passive, work.path());
        active.tick(Local::now());

        passive.run_now(&j.id).unwrap();
        let paths = Paths::under(home.path());
        assert!(pending_requests(&paths).contains(&j.id));
        assert!(view(&passive.inner.lock().unwrap())[0].queued, "shown as waiting");
        assert!(passive.run_now(&j.id).unwrap_err().contains("already"), "no double request");
        assert!(passive.run_now("nope").is_err());

        let (fire, _) = active.tick(Local::now());
        assert_eq!(fire, vec![(j.id.clone(), "manual")]);
        assert!(pending_requests(&paths).is_empty(), "the request is consumed");

        // The passive side shows the active one's state from its status file.
        active.inner.lock().unwrap().running.insert(j.id.clone());
        active.changed();
        let v = view(&passive.inner.lock().unwrap());
        assert!(v[0].running);
        assert_eq!(v[0].next_run, active.inner.lock().unwrap().due.get(&j.id).copied());
        assert!(delete(&mut passive.inner.lock().unwrap(), &j.id).is_err(), "busy elsewhere");
        assert_eq!(runner(&passive.inner.lock().unwrap()), "other");
    }

    #[tokio::test]
    async fn spawn_passes_argv_and_cwd_and_times_out_the_group() {
        let work = tempfile::tempdir().unwrap();
        let canon = fs::canonicalize(work.path()).unwrap();
        let env: HashMap<String, String> =
            [("PATH".to_string(), "/usr/bin:/bin".to_string())].into();
        // A stand-in for claude: prints its cwd and last argv element.
        let script = work.path().join("fake-claude");
        fs::write(
            &script,
            "#!/bin/sh\npwd\nfor a; do last=$a; done\nprintf '%s' \"$last\"\n",
        )
        .unwrap();
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();
        let args = claude_args("hi; touch PWNED", true, false);
        let s = spawn_run(
            script.to_str().unwrap(),
            &args,
            canon.to_str().unwrap(),
            &env,
            std::time::Duration::from_secs(10),
        )
        .await
        .unwrap();
        assert_eq!(s.exit_code, Some(0));
        assert!(s.stdout.starts_with(canon.to_str().unwrap()));
        assert!(s.stdout.ends_with("hi; touch PWNED"));
        assert!(
            !canon.join("PWNED").exists(),
            "the prompt never reaches a shell"
        );

        // Timeout stops the child AND what it started.
        let marker = canon.join("grandchild-alive");
        let slow = work.path().join("slow");
        fs::write(
            &slow,
            format!(
                "#!/bin/sh\n(sleep 3; touch '{}') &\nsleep 30\n",
                marker.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&slow, fs::Permissions::from_mode(0o755)).unwrap();
        let t0 = std::time::Instant::now();
        let s = spawn_run(
            slow.to_str().unwrap(),
            &[],
            canon.to_str().unwrap(),
            &env,
            std::time::Duration::from_secs(1),
        )
        .await
        .unwrap();
        assert!(s.timed_out);
        assert!(t0.elapsed() < std::time::Duration::from_secs(8));
        tokio::time::sleep(std::time::Duration::from_secs(4)).await;
        assert!(
            !marker.exists(),
            "the background grandchild was stopped with the group"
        );
    }
}

#[cfg(test)]
mod live {
    use super::*;

    /// Real headless run with the operator's own environment. Costs a few cents:
    /// `cargo test --lib schedules::live -- --ignored --nocapture`
    #[tokio::test]
    #[ignore = "runs the real claude CLI"]
    async fn real_claude_headless_run_sees_mcp_tools() {
        let work = tempfile::tempdir().unwrap();
        let env = tauri::async_runtime::spawn_blocking(login_env)
            .await
            .unwrap()
            .clone();
        let bin = crate::agents::claude_bin().to_string();
        let args = claude_args("List the names of the MCP servers whose tools you can call, comma separated, nothing else.", true, true);
        let s = spawn_run(
            &bin,
            &args,
            work.path().to_str().unwrap(),
            &env,
            std::time::Duration::from_secs(300),
        )
        .await
        .unwrap();
        let (st, cost, text) = classify(s.exit_code, &s.stdout, &s.stderr);
        println!("bin={bin}\nstatus={st:?} cost={cost:?}\noutput={text}");
        assert_eq!(st, RunStatus::Success);
    }
}
