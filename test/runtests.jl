using Test
using DBInterface
using JSON3
using SQLite
using Trackio

function with_temp_trackio_dir(f::Function)
    directory = mktempdir()
    withenv(
        "TRACKIO_DIR" => directory,
        "TRACKIO_SPACE_ID" => nothing,
        "TRACKIO_SERVER_URL" => nothing,
        "TRACKIO_WRITE_TOKEN" => nothing,
    ) do
        try
            return f(directory)
        finally
            Trackio.finish()
        end
    end
end

function copy_row(row)
    names = Tuple(propertynames(row))
    values = Tuple(getproperty(row, name) for name in names)
    return NamedTuple{names}(values)
end

function db_rows(db_path::AbstractString, sql::AbstractString)
    db = SQLite.DB(String(db_path))
    try
        rows = Any[]
        for row in DBInterface.execute(db, String(sql))
            push!(rows, copy_row(row))
        end
        return rows
    finally
        DBInterface.close!(db)
    end
end

@testset "local SQLite storage" begin
    with_temp_trackio_dir() do _
        db_path = Trackio.init_db("Proj 1!")
        @test basename(db_path) == "Proj1.db"
        @test isfile(db_path)

        tables = Set(
            row.name for row in
            db_rows(db_path, "SELECT name FROM sqlite_master WHERE type = 'table'")
        )
        @test Set([
            "metrics",
            "configs",
            "system_metrics",
            "traces",
            "project_metadata",
            "pending_uploads",
            "alerts",
        ]) ⊆ tables

        metric_columns =
            Set(row.name for row in db_rows(db_path, "PRAGMA table_info(metrics)"))
        @test Set([
            "id",
            "run_id",
            "timestamp",
            "run_name",
            "step",
            "metrics",
            "log_id",
            "space_id",
        ]) ⊆ metric_columns

        metric_indexes =
            Set(row.name for row in db_rows(db_path, "PRAGMA index_list(metrics)"))
        @test "idx_metrics_run_step" in metric_indexes
        @test "idx_metrics_run_timestamp" in metric_indexes
        @test "idx_metrics_log_id" in metric_indexes
        @test "idx_metrics_pending" in metric_indexes
    end
end

@testset "metrics and config writes" begin
    with_temp_trackio_dir() do _
        run = Trackio.init(
            "metrics_project";
            name = "metrics_run",
            config = Dict("epochs" => 3),
        )
        Trackio.log(run, Dict("loss" => 0.5, "nan" => NaN, "inf" => Inf, "ninf" => -Inf))
        Trackio.finish(run)

        db_path = Trackio.project_db_path("metrics_project")
        metric_rows = db_rows(
            db_path,
            "SELECT run_id, run_name, step, metrics, log_id, space_id FROM metrics",
        )
        @test length(metric_rows) == 1
        row = only(metric_rows)
        @test row.run_id == run.id
        @test row.run_name == "metrics_run"
        @test row.step == 0
        @test !ismissing(row.log_id)
        @test ismissing(row.space_id)

        metrics = JSON3.read(row.metrics)
        @test metrics.loss == 0.5
        @test metrics.nan == "NaN"
        @test metrics.inf == "Infinity"
        @test metrics.ninf == "-Infinity"

        config_rows = db_rows(db_path, "SELECT run_id, run_name, config FROM configs")
        @test length(config_rows) == 1
        config = JSON3.read(only(config_rows).config)
        @test config.epochs == 3
        @test haskey(config, :_Created)
        @test haskey(config, :_Username)
        @test haskey(config, :_Group)
    end
end

@testset "system metrics and alerts" begin
    with_temp_trackio_dir() do _
        run = Trackio.init("events_project"; name = "events_run")
        Trackio.log_system(run, Dict("cpu" => 12.5))
        Trackio.alert(run, "training done"; text = "ok", level = :info, step = 7)
        Trackio.finish(run)

        db_path = Trackio.project_db_path("events_project")
        system_rows = db_rows(
            db_path,
            "SELECT run_id, run_name, metrics, log_id, space_id FROM system_metrics",
        )
        @test length(system_rows) == 1
        system_row = only(system_rows)
        @test system_row.run_id == run.id
        @test system_row.run_name == "events_run"
        @test JSON3.read(system_row.metrics).cpu == 12.5
        @test !ismissing(system_row.log_id)
        @test ismissing(system_row.space_id)

        alert_rows = db_rows(
            db_path,
            "SELECT run_id, run_name, title, text, level, step, alert_id FROM alerts",
        )
        @test length(alert_rows) == 1
        alert_row = only(alert_rows)
        @test alert_row.run_id == run.id
        @test alert_row.run_name == "events_run"
        @test alert_row.title == "training done"
        @test alert_row.text == "ok"
        @test alert_row.level == "info"
        @test alert_row.step == 7
        @test !ismissing(alert_row.alert_id)
    end
end

@testset "local media" begin
    with_temp_trackio_dir() do directory
        source = joinpath(directory, "image.png")
        write(source, "fake image")

        run = Trackio.init("media_project"; name = "media_run")
        Trackio.log(
            run,
            Dict("image" => Trackio.Image(source; caption = "sample"));
            step = 4,
        )
        Trackio.finish(run)

        row = only(
            db_rows(
                Trackio.project_db_path("media_project"),
                "SELECT metrics FROM metrics",
            ),
        )
        image = JSON3.read(row.metrics).image
        file_path = String(image.file_path)
        @test image._type == "trackio.image"
        @test image.caption == "sample"
        @test splitpath(file_path)[1:3] == ["media_project", "media_run", "4"]
        @test endswith(file_path, ".png")
        @test isfile(joinpath(Trackio.media_dir(), file_path))
    end
end

@testset "local resume" begin
    with_temp_trackio_dir() do _
        first_run = Trackio.init("resume_project"; name = "same_run")
        Trackio.log(first_run, Dict("loss" => 1.0))
        Trackio.finish(first_run)

        resumed_run = Trackio.init("resume_project"; name = "same_run", resume = "allow")
        @test resumed_run.id == first_run.id
        @test resumed_run.next_step == 1
        Trackio.log(resumed_run, Dict("loss" => 0.5))
        Trackio.finish(resumed_run)

        steps = [
            row.step for row in db_rows(
                Trackio.project_db_path("resume_project"),
                "SELECT step FROM metrics ORDER BY step",
            )
        ]
        @test steps == [0, 1]

        @test_throws ErrorException Trackio.init(
            "resume_project";
            name = "missing_run",
            resume = "must",
        )
    end
end

@testset "report_to validation" begin
    with_temp_trackio_dir() do _
        @test_throws ErrorException Trackio.init("local_project"; space_id = "user/space")
        @test_throws ErrorException Trackio.init(
            "local_project";
            server_url = "http://127.0.0.1:7860",
        )

        withenv("TRACKIO_SPACE_ID" => "user/space") do
            run = Trackio.init("local_project"; name = "ignores_remote_env")
            @test run.backend isa Trackio.LocalBackend
            @test run.client === nothing
            Trackio.finish(run)
        end

        @test_throws ErrorException Trackio.init("remote_project"; report_to = :remote)
    end
end
