const DB_EXT = ".db"
const TRACKIO_LOCK_EX = 2
const TRACKIO_LOCK_NB = 4
const TRACKIO_LOCK_UN = 8
const PROCESS_LOCKS = Dict{String,ReentrantLock}()
const PROCESS_LOCKS_LOCK = ReentrantLock()

function trackio_dir()
    configured = get(ENV, "TRACKIO_DIR", "")
    !isempty(configured) && return configured
    hf_home = get(ENV, "HF_HOME", joinpath(homedir(), ".cache", "huggingface"))
    return joinpath(hf_home, "trackio")
end

media_dir() = joinpath(trackio_dir(), "media")

function project_db_filename(project::AbstractString)
    safe_project = join(
        c for c in String(project) if isletter(c) || isnumeric(c) || c == '-' || c == '_'
    )
    safe_project = rstrip(safe_project)
    isempty(safe_project) && (safe_project = "default")
    return safe_project * DB_EXT
end

project_db_path(project::AbstractString) =
    joinpath(trackio_dir(), project_db_filename(project))

function project_lock(lockfile_path::String)
    lock(PROCESS_LOCKS_LOCK)
    try
        return get!(PROCESS_LOCKS, lockfile_path, ReentrantLock())
    finally
        unlock(PROCESS_LOCKS_LOCK)
    end
end

function try_acquire_flock!(file)
    for attempt = 1:100
        result = try
            ccall(
                :flock,
                Cint,
                (Base.RawFD, Cint),
                Base.fd(file),
                TRACKIO_LOCK_EX | TRACKIO_LOCK_NB,
            )
        catch
            return false
        end
        result == 0 && return true
        attempt == 100 && error("Could not acquire database lock after 10 seconds")
        sleep(0.1)
    end
    return false
end

function release_flock!(file)
    try
        ccall(:flock, Cint, (Base.RawFD, Cint), Base.fd(file), TRACKIO_LOCK_UN)
    catch
    end
    return nothing
end

function sqlite_execute!(db::SQLite.DB, sql::AbstractString)
    rows = DBInterface.execute(db, String(sql))
    for _ in rows
    end
    return nothing
end

function sqlite_execute!(db::SQLite.DB, sql::AbstractString, params)
    rows = DBInterface.execute(db, String(sql), params)
    for _ in rows
    end
    return nothing
end

function with_process_lock(f::Function, project::AbstractString)
    lockfile_path = joinpath(trackio_dir(), String(project) * ".lock")
    lock = project_lock(lockfile_path)
    Base.lock(lock)
    try
        mkpath(dirname(lockfile_path))
        file = open(lockfile_path, "w")
        flocked = false
        try
            flocked = try_acquire_flock!(file)
            return f()
        finally
            flocked && release_flock!(file)
            close(file)
        end
    finally
        unlock(lock)
    end
end

function configure_sqlite!(db::SQLite.DB)
    sqlite_execute!(db, "PRAGMA journal_mode = WAL")
    sqlite_execute!(db, "PRAGMA synchronous = NORMAL")
    sqlite_execute!(db, "PRAGMA temp_store = MEMORY")
    sqlite_execute!(db, "PRAGMA cache_size = -20000")
    return db
end

function with_sqlite_connection(f::Function, db_path::AbstractString)
    db = SQLite.DB(String(db_path))
    try
        configure_sqlite!(db)
        return f(db)
    finally
        DBInterface.close!(db)
    end
end

function with_sqlite_transaction(f::Function, db::SQLite.DB)
    sqlite_execute!(db, "BEGIN")
    try
        result = f()
        sqlite_execute!(db, "COMMIT")
        return result
    catch
        try
            sqlite_execute!(db, "ROLLBACK")
        catch
        end
        rethrow()
    end
end

function execute_ignore_error(db::SQLite.DB, sql::AbstractString)
    try
        sqlite_execute!(db, String(sql))
    catch
    end
    return nothing
end

function init_db(project::AbstractString)
    db_path = project_db_path(project)
    mkpath(dirname(db_path))
    with_process_lock(project) do
        with_sqlite_connection(db_path) do db
            with_sqlite_transaction(db) do
                sqlite_execute!(
                    db,
                    """
                    CREATE TABLE IF NOT EXISTS metrics (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        run_id TEXT NOT NULL,
                        timestamp TEXT NOT NULL,
                        run_name TEXT NOT NULL,
                        step INTEGER NOT NULL,
                        metrics TEXT NOT NULL,
                        log_id TEXT,
                        space_id TEXT
                    )
                    """,
                )
                sqlite_execute!(
                    db,
                    """
                    CREATE TABLE IF NOT EXISTS configs (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        run_id TEXT NOT NULL,
                        run_name TEXT NOT NULL,
                        config TEXT NOT NULL,
                        created_at TEXT NOT NULL,
                        UNIQUE(run_id)
                    )
                    """,
                )
                sqlite_execute!(
                    db,
                    """
                    CREATE TABLE IF NOT EXISTS system_metrics (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        run_id TEXT NOT NULL,
                        timestamp TEXT NOT NULL,
                        run_name TEXT NOT NULL,
                        metrics TEXT NOT NULL,
                        log_id TEXT,
                        space_id TEXT
                    )
                    """,
                )
                sqlite_execute!(
                    db,
                    """
                    CREATE TABLE IF NOT EXISTS traces (
                        id TEXT PRIMARY KEY,
                        run_id TEXT NOT NULL,
                        timestamp TEXT NOT NULL,
                        run_name TEXT NOT NULL,
                        step INTEGER NOT NULL,
                        key TEXT NOT NULL,
                        trace_index INTEGER,
                        messages TEXT NOT NULL,
                        metadata TEXT NOT NULL,
                        search_text TEXT NOT NULL,
                        log_id TEXT,
                        space_id TEXT
                    )
                    """,
                )
                sqlite_execute!(
                    db,
                    """
                    CREATE TABLE IF NOT EXISTS project_metadata (
                        key TEXT PRIMARY KEY,
                        value TEXT NOT NULL
                    )
                    """,
                )
                sqlite_execute!(
                    db,
                    """
                    CREATE TABLE IF NOT EXISTS pending_uploads (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        space_id TEXT NOT NULL,
                        run_id TEXT,
                        run_name TEXT,
                        step INTEGER,
                        file_path TEXT NOT NULL,
                        relative_path TEXT,
                        created_at TEXT NOT NULL
                    )
                    """,
                )
                sqlite_execute!(
                    db,
                    """
                    CREATE TABLE IF NOT EXISTS alerts (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        run_id TEXT NOT NULL,
                        timestamp TEXT NOT NULL,
                        run_name TEXT NOT NULL,
                        title TEXT NOT NULL,
                        text TEXT,
                        level TEXT NOT NULL DEFAULT 'warn',
                        step INTEGER,
                        alert_id TEXT
                    )
                    """,
                )

                execute_ignore_error(db, "ALTER TABLE metrics ADD COLUMN log_id TEXT")
                execute_ignore_error(db, "ALTER TABLE metrics ADD COLUMN space_id TEXT")
                execute_ignore_error(
                    db,
                    "ALTER TABLE system_metrics ADD COLUMN log_id TEXT",
                )
                execute_ignore_error(
                    db,
                    "ALTER TABLE system_metrics ADD COLUMN space_id TEXT",
                )

                sqlite_execute!(
                    db,
                    "CREATE INDEX IF NOT EXISTS idx_metrics_run_step ON metrics(run_id, step)",
                )
                sqlite_execute!(
                    db,
                    "CREATE INDEX IF NOT EXISTS idx_metrics_run_timestamp ON metrics(run_id, timestamp)",
                )
                sqlite_execute!(
                    db,
                    "CREATE INDEX IF NOT EXISTS idx_configs_run_name ON configs(run_name)",
                )
                sqlite_execute!(
                    db,
                    "CREATE INDEX IF NOT EXISTS idx_system_metrics_run_timestamp ON system_metrics(run_id, timestamp)",
                )
                sqlite_execute!(
                    db,
                    "CREATE INDEX IF NOT EXISTS idx_traces_run_step ON traces(run_id, step)",
                )
                sqlite_execute!(
                    db,
                    "CREATE INDEX IF NOT EXISTS idx_traces_run_timestamp ON traces(run_id, timestamp)",
                )
                sqlite_execute!(
                    db,
                    "CREATE INDEX IF NOT EXISTS idx_traces_search ON traces(search_text)",
                )
                sqlite_execute!(
                    db,
                    "CREATE INDEX IF NOT EXISTS idx_alerts_run ON alerts(run_id)",
                )
                sqlite_execute!(
                    db,
                    "CREATE INDEX IF NOT EXISTS idx_alerts_timestamp ON alerts(timestamp)",
                )
                sqlite_execute!(
                    db,
                    """
                    CREATE UNIQUE INDEX IF NOT EXISTS idx_alerts_alert_id
                    ON alerts(alert_id) WHERE alert_id IS NOT NULL
                    """,
                )
                sqlite_execute!(
                    db,
                    """
                    CREATE UNIQUE INDEX IF NOT EXISTS idx_metrics_log_id
                    ON metrics(log_id) WHERE log_id IS NOT NULL
                    """,
                )
                sqlite_execute!(
                    db,
                    """
                    CREATE INDEX IF NOT EXISTS idx_metrics_pending
                    ON metrics(space_id) WHERE space_id IS NOT NULL
                    """,
                )
                sqlite_execute!(
                    db,
                    """
                    CREATE UNIQUE INDEX IF NOT EXISTS idx_system_metrics_log_id
                    ON system_metrics(log_id) WHERE log_id IS NOT NULL
                    """,
                )
                sqlite_execute!(
                    db,
                    """
                    CREATE INDEX IF NOT EXISTS idx_system_metrics_pending
                    ON system_metrics(space_id) WHERE space_id IS NOT NULL
                    """,
                )
            end
        end
    end
    return db_path
end

is_sql_null(value) = value === nothing || value === missing
sql_value(value) = is_sql_null(value) ? nothing : value

function first_row(rows)
    first = nothing
    for row in rows
        if first === nothing
            names = Tuple(propertynames(row))
            values = Tuple(getproperty(row, name) for name in names)
            first = NamedTuple{names}(values)
        end
    end
    return first
end

function no_such_table_error(err)
    return occursin("no such table", lowercase(sprint(showerror, err)))
end

function local_max_step_for_run_id(db::SQLite.DB, run_id::String)
    row = first_row(
        DBInterface.execute(
            db,
            "SELECT MAX(step) AS max_step FROM metrics WHERE run_id = ?",
            (run_id,),
        ),
    )
    row === nothing && return nothing
    value = row.max_step
    return is_sql_null(value) ? nothing : Int(value)
end

function normalize_steps(db::SQLite.DB, run_id::String, steps::Vector)
    current_step = nothing
    normalized = Int[]
    for step in steps
        if is_sql_null(step)
            if current_step === nothing
                last_step = local_max_step_for_run_id(db, run_id)
                current_step = last_step === nothing ? 0 : last_step + 1
            end
            push!(normalized, current_step)
            current_step += 1
        else
            push!(normalized, Int(step))
        end
    end
    return normalized
end

function normalize_timestamps(timestamps::Vector, count::Int)
    default_timestamp = utc_timestamp()
    isempty(timestamps) && return fill(default_timestamp, count)
    return [
        is_sql_null(timestamp) ? default_timestamp : String(timestamp) for
        timestamp in timestamps
    ]
end

function entry_run_id(entry::Dict{String,Any}, run::String)
    run_id = get(entry, "run_id", nothing)
    return is_sql_null(run_id) ? run : String(run_id)
end

function grouped_log_entries(logs::Vector{Dict{String,Any}})
    groups = Dict{Tuple{String,String,String},Dict{String,Any}}()
    for entry in logs
        project = String(entry["project"])
        run = String(entry["run"])
        run_id = entry_run_id(entry, run)
        data = get!(groups, (project, run, run_id)) do
            Dict{String,Any}(
                "metrics" => Any[],
                "steps" => Any[],
                "timestamps" => Any[],
                "log_ids" => Any[],
                "config" => nothing,
            )
        end
        push!(data["metrics"], entry["metrics"])
        push!(data["steps"], get(entry, "step", nothing))
        push!(data["timestamps"], get(entry, "timestamp", nothing))
        push!(data["log_ids"], get(entry, "log_id", nothing))
        if data["config"] === nothing && haskey(entry, "config")
            data["config"] = entry["config"]
        end
    end
    return groups
end

function grouped_system_log_entries(system_logs::Vector{Dict{String,Any}})
    groups = Dict{Tuple{String,String,String},Dict{String,Any}}()
    for entry in system_logs
        project = String(entry["project"])
        run = String(entry["run"])
        run_id = entry_run_id(entry, run)
        data = get!(groups, (project, run, run_id)) do
            Dict{String,Any}("metrics" => Any[], "timestamps" => Any[], "log_ids" => Any[])
        end
        push!(data["metrics"], entry["metrics"])
        push!(data["timestamps"], get(entry, "timestamp", nothing))
        push!(data["log_ids"], get(entry, "log_id", nothing))
    end
    return groups
end

function grouped_alert_entries(alerts::Vector{Dict{String,Any}})
    groups = Dict{Tuple{String,String,String},Dict{String,Any}}()
    for entry in alerts
        project = String(entry["project"])
        run = String(entry["run"])
        run_id = entry_run_id(entry, run)
        data = get!(groups, (project, run, run_id)) do
            Dict{String,Any}(
                "titles" => Any[],
                "texts" => Any[],
                "levels" => Any[],
                "steps" => Any[],
                "timestamps" => Any[],
                "alert_ids" => Any[],
            )
        end
        push!(data["titles"], entry["title"])
        push!(data["texts"], get(entry, "text", nothing))
        push!(data["levels"], entry["level"])
        push!(data["steps"], get(entry, "step", nothing))
        push!(data["timestamps"], get(entry, "timestamp", nothing))
        push!(data["alert_ids"], get(entry, "alert_id", nothing))
    end
    return groups
end

function insert_metric_groups!(db::SQLite.DB, groups)
    for ((_, run, run_id), data) in groups
        metrics = data["metrics"]
        isempty(metrics) && continue
        steps = normalize_steps(db, run_id, data["steps"])
        timestamps = normalize_timestamps(data["timestamps"], length(metrics))
        log_ids = data["log_ids"]
        for index in eachindex(metrics)
            sqlite_execute!(
                db,
                """
                INSERT OR IGNORE INTO metrics
                (timestamp, run_id, run_name, step, metrics, log_id, space_id)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    timestamps[index],
                    run_id,
                    run,
                    steps[index],
                    JSON3.write(metrics[index]),
                    sql_value(log_ids[index]),
                    nothing,
                ),
            )
        end

        config = data["config"]
        if config !== nothing
            sqlite_execute!(
                db,
                """
                INSERT OR REPLACE INTO configs
                (run_id, run_name, config, created_at)
                VALUES (?, ?, ?, ?)
                """,
                (run_id, run, JSON3.write(config), utc_timestamp()),
            )
        end
    end
    return nothing
end

function insert_system_log_groups!(db::SQLite.DB, groups)
    for ((_, run, run_id), data) in groups
        metrics = data["metrics"]
        isempty(metrics) && continue
        timestamps = normalize_timestamps(data["timestamps"], length(metrics))
        log_ids = data["log_ids"]
        for index in eachindex(metrics)
            sqlite_execute!(
                db,
                """
                INSERT OR IGNORE INTO system_metrics
                (timestamp, run_id, run_name, metrics, log_id, space_id)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (
                    timestamps[index],
                    run_id,
                    run,
                    JSON3.write(metrics[index]),
                    sql_value(log_ids[index]),
                    nothing,
                ),
            )
        end
    end
    return nothing
end

function insert_alert_groups!(db::SQLite.DB, groups)
    for ((_, run, run_id), data) in groups
        titles = data["titles"]
        isempty(titles) && continue
        timestamps = normalize_timestamps(data["timestamps"], length(titles))
        for index in eachindex(titles)
            sqlite_execute!(
                db,
                """
                INSERT OR IGNORE INTO alerts
                (run_id, timestamp, run_name, title, text, level, step, alert_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    run_id,
                    timestamps[index],
                    run,
                    String(titles[index]),
                    sql_value(data["texts"][index]),
                    String(data["levels"][index]),
                    sql_value(data["steps"][index]),
                    sql_value(data["alert_ids"][index]),
                ),
            )
        end
    end
    return nothing
end

function batch_projects(
    logs::Vector{Dict{String,Any}},
    system_logs::Vector{Dict{String,Any}},
    alerts::Vector{Dict{String,Any}},
)
    projects = String[]
    for collection in (logs, system_logs, alerts)
        for entry in collection
            push!(projects, String(entry["project"]))
        end
    end
    return unique(projects)
end

function entries_for_project(entries::Vector{Dict{String,Any}}, project::String)
    return [entry for entry in entries if String(entry["project"]) == project]
end

function write_local_batch!(
    logs::Vector{Dict{String,Any}},
    system_logs::Vector{Dict{String,Any}},
    alerts::Vector{Dict{String,Any}},
)
    for project in batch_projects(logs, system_logs, alerts)
        db_path = init_db(project)
        with_process_lock(project) do
            with_sqlite_connection(db_path) do db
                with_sqlite_transaction(db) do
                    insert_metric_groups!(
                        db,
                        grouped_log_entries(entries_for_project(logs, project)),
                    )
                    insert_system_log_groups!(
                        db,
                        grouped_system_log_entries(
                            entries_for_project(system_logs, project),
                        ),
                    )
                    insert_alert_groups!(
                        db,
                        grouped_alert_entries(entries_for_project(alerts, project)),
                    )
                end
            end
        end
    end
    return nothing
end

function local_latest_matching_run(project::String, name::String)
    db_path = project_db_path(project)
    isfile(db_path) || return nothing
    try
        return with_sqlite_connection(db_path) do db
            row = first_row(
                DBInterface.execute(
                    db,
                    """
                    SELECT run_id, run_name, MIN(timestamp) AS created_at
                    FROM metrics
                    WHERE run_name = ?
                    GROUP BY run_id, run_name
                    ORDER BY created_at DESC
                    LIMIT 1
                    """,
                    (name,),
                ),
            )
            row === nothing && return nothing
            return Dict{String,Any}(
                "id" => String(row.run_id),
                "name" => String(row.run_name),
                "created_at" => String(row.created_at),
            )
        end
    catch err
        no_such_table_error(err) && return nothing
        rethrow()
    end
end

function local_last_step(project::String, name::String, run_id::String)
    db_path = project_db_path(project)
    isfile(db_path) || return nothing
    try
        return with_sqlite_connection(db_path) do db
            row = first_row(
                DBInterface.execute(
                    db,
                    "SELECT MAX(step) AS max_step FROM metrics WHERE run_id = ?",
                    (run_id,),
                ),
            )
            row === nothing && return nothing
            value = row.max_step
            return is_sql_null(value) ? nothing : Int(value)
        end
    catch err
        no_such_table_error(err) && return nothing
        rethrow()
    end
end

function local_media_file_path(
    project::AbstractString,
    run::AbstractString,
    step::Integer,
    extension::AbstractString,
)
    directory = joinpath(media_dir(), String(project), String(run), string(step))
    mkpath(directory)
    return joinpath(directory, string(uuid4()) * "." * String(extension))
end
