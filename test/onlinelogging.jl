using Test
import Logging
import ClimaUtilities.OnlineLogging:
    WallTimeInfo, _update!, report_walltime, _time_and_units_str, _trunc_time

@testset "OnlineLogging Tests" begin
    # Mock integrator struct for testing
    Base.@kwdef struct MockIntegrator
        sol::Any
        dt::Any
        t::Any
        step::Any
    end

    @testset "WallTimeInfo" begin
        wt = WallTimeInfo()
        @test wt.n_calls[] == 0
        @test wt.t_wall_last[] == -1.0
        @test wt.∑Δt_wall[] == 0.0
    end

    @testset "_update!" begin
        wt = WallTimeInfo()

        # First call
        _update!(wt)
        @test wt.n_calls[] == 1
        @test wt.∑Δt_wall[] == 0.0

        # Second call
        _update!(wt)
        @test wt.n_calls[] == 2
        @test wt.∑Δt_wall[] == 0.0

        # Third call (compilation time compensation)
        t1 = time()
        sleep(0.1) # Introduce a small delay to simulate elapsed time
        _update!(wt)
        t2 = time()
        @test wt.n_calls[] == 3
        @test wt.∑Δt_wall[] ≈ 2 * (t2 - t1) atol = 0.1

        # Fourth call (normal update)
        t1 = time()
        sleep(0.1)
        _update!(wt)
        t2 = time()

        @test wt.n_calls[] == 4
        @test isapprox(wt.∑Δt_wall[], 2 * (time() - t1) + (t2 - t1), atol = 0.1)

    end

    @testset "report_walltime" begin
        wt = WallTimeInfo()
        integrator = MockIntegrator(;
            sol = (; prob = (; tspan = (0.0, 10.0))),
            dt = 0.1,
            t = 2.0,
            step = 20,
        )

        io = IOBuffer()
        Logging.with_logger(Logging.SimpleLogger(io)) do
            report_walltime(wt, integrator)
        end
        output_string = String(take!(io))

        # Check that the expected information is present in the output
        @test occursin("Progress", output_string)
        @test occursin("simulation_time", output_string)
        @test occursin("n_steps_completed = 20", output_string) # Check for correct step count

        # Reset WallTimeInfo and introduce delays:
        wt = WallTimeInfo()
        io = IOBuffer()
        dt = 3600.0
        n_steps = 32
        tf = n_steps*dt
        delay_s = 0.2
        reporting_times = (1, 2, 8, 16)
        Logging.with_logger(Logging.SimpleLogger(io)) do
            for step in 1:(n_steps / 2.0)
                integrator = MockIntegrator(;
                    sol = (; prob = (; tspan = (0.0, tf))),
                    dt = dt,
                    t = step * dt,
                    step = step,
                )
                step in reporting_times && report_walltime(wt, integrator)
                sleep(delay_s)
            end
        end
        output_string = String(take!(io))

        # Check if timings are reported now that they're non-zero
        @test occursin("wall_time_per_step", output_string)
        @test occursin("wall_time_total", output_string)
        @test occursin("wall_time_remaining", output_string)
        @test occursin("wall_time_spent", output_string)
        @test occursin("percent_complete", output_string)

        @test occursin("estimated_sypd", output_string)
        @test occursin("date_now", output_string)
        @test occursin("estimated_finish_date", output_string)
        last_rep = split(output_string, "Info:")[end]
        reported_sypd =
            parse(Int, match(r"estimated_sypd = (\d*)", last_rep).captures[1])
        time_remaining_s, time_remaining_ms = match(
            r"wall_time_remaining = (\d*) seconds, (\d*) milliseconds",
            last_rep,
        ).captures
        time_spent_s, time_spent_ms = match(
            r"wall_time_spent = (\d*) seconds, (\d*) milliseconds",
            last_rep,
        ).captures
        time_total_s, time_total_ms = match(
            r"wall_time_total = (\d*) seconds, (\d*) milliseconds",
            last_rep,
        ).captures
        s_and_ms_to_s = (s, ms) -> parse(Int, s) + 0.001 * parse(Int, ms)
        reported_time_spent = s_and_ms_to_s(time_spent_s, time_spent_ms)
        reported_time_remaining =
            s_and_ms_to_s(time_remaining_s, time_remaining_ms)
        reported_time_total = s_and_ms_to_s(time_total_s, time_total_ms)
        theoretical_time_total = delay_s * n_steps
        theoretical_sypd = (24*3600) / (delay_s * 365 * 24 * 3600.0 / dt)
        @test isapprox(
            reported_time_remaining,
            theoretical_time_total/2;
            rtol = 0.1,
        )
        @test isapprox(
            reported_time_spent,
            theoretical_time_total/2;
            rtol = 0.1,
        )
        @test isapprox(reported_time_total, theoretical_time_total; rtol = 0.1)
        @test isapprox(reported_sypd, theoretical_sypd; rtol = 0.1)
    end

    @testset "_time_and_units_str" begin
        @test _time_and_units_str(0.0) == "0 seconds"
        @test _time_and_units_str(1.0) == "1 second"
        @test _time_and_units_str(60.0) == "1 minute"
        @test _time_and_units_str(3600.0) == "1 hour"
        @test _time_and_units_str(3661.0) == "1 hour, 1 minute" # Test truncation
    end

    @testset "_trunc_time" begin
        @test _trunc_time("1 hour, 1 minute, 1 second") == "1 hour, 1 minute"
        @test _trunc_time("1 minute, 1 second") == "1 minute, 1 second"
        @test _trunc_time("1 second") == "1 second"
    end
end
