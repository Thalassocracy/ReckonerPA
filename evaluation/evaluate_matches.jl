using Reckoner

import LibPQ

include("reckonerPA_equations.jl")

const EVAL_LIMIT = 4000

function evaluate_matches(conn; refresh_view = true)
    query::String = "
                    SELECT
                        player_type,
                        player_id,
                        time_start as timestamp,
                        match_id,
                        team_num as team_id,
                        win,
                        team_size,
                        team_size_mean,
                        team_size_var,
                        team_count,
                        eco,
                        eco_mean,
                        eco_var,
                        all_dead,
                        shared,
                        titans,
                        ranked,
                        tourney,
                        win_chance,
                        player_num 
                    FROM reckoner.matchrows
                    WHERE NOT SCORED
                    ORDER BY time_start
                    LIMIT $EVAL_LIMIT;
                    "
    res = LibPQ.execute(conn, query)

    println("Checkpoint 1: unscored matches fetched")

    player_hist::Dict{PlayerId, PAMatches} = Dict()
    game_hist::Dict{Int64, Vector{Tuple{PAMatch, PlayerId}}} = Dict()
    game_order::Vector{Int64} = Vector{Int64}()
    players_seen::Set{PlayerId} = Set{PlayerId}()

    function add_to_player_hist!(pid::PlayerId, game::PAMatch)
        if pid in keys(player_hist)
            push!(player_hist[pid], game)
        else
            player_hist[pid] = PAMatches([game])
        end
    end

    for row in res
        curr::PAMatch = row |> PAMatch
        pid::PlayerId = (row.player_type, row.player_id)
        
        push!(players_seen, pid)

        if row.match_id in keys(game_hist)
            push!(game_hist[row.match_id], (curr, pid))
        else
            game_hist[row.match_id] = [(curr, pid)]
            push!(game_order, row.match_id)
        end
    end
    
    println("Checkpoint 2: unscored matches processed")

    query = "
        SELECT
            player_type,
            player_id,
            time_start as timestamp,
            match_id,
            team_num as team_id,
            win,
            team_size,
            team_size_mean,
            team_size_var,
            team_count,
            eco,
            eco_mean,
            eco_var,
            all_dead,
            shared,
            titans,
            ranked,
            tourney,
            win_chance,
            player_num,
            alpha,
            beta,
            win_chance  
        FROM reckoner.matchrows
        WHERE SCORED
        AND (player_type, player_id) IN ("
    for pid in players_seen
        query *= "('$(sanitize(pid[1]))','$(sanitize(pid[2]))'),"
    end
    query = query[1:end-1] * ");"
    # query = "
    #         SELECT
    #             player_type,
    #             player_id,
    #             time_start as timestamp,
    #             match_id,
    #             team_num as team_id,
    #             win,
    #             team_size,
    #             team_size_mean,
    #             team_size_var,
    #             team_count,
    #             eco,
    #             eco_mean,
    #             eco_var,
    #             all_dead,
    #             shared,
    #             titans,
    #             ranked,
    #             tourney,
    #             win_chance,
    #             player_num,
    #             alpha,
    #             beta,
    #             win_chance  
    #         FROM reckoner.matchrows
    #         WHERE SCORED;"

    res = LibPQ.execute(conn, query)

    
    println("Checkpoint 3: scored matches fetched")

    for row in res
        add_to_player_hist!((row.player_type, row.player_id), PAMatch(row))
    end

    println("Checkpoint 4: scored matches processed")

    for id in game_order
        game = values(game_hist[id])
        curr::Vector{PAMatch} = [i[1] for i in game]
        # if length(game) != round(Int64, curr[1].team_size_mean * curr[1].team_count)
        #     continue
        # end

        if length(unique([i.team_id for i in curr])) < curr[1].team_count
            continue
        end

        if length(unique([i.team_id for i in curr])) < 2
            println("single team: $id")
            continue
        end

        past_matches::Vector{PAMatches} = aup.(curr, [pa_reck])
        for i in 1:length(curr)
            if (game[i][2] in keys(player_hist)) 
                past_matches[i] = merge(past_matches[i], player_hist[game[i][2]])
            end
        end
        challenges::Vector{Beta{Float64}} = eff_challenge(curr, past_matches, pa_reck)
        chances::Vector{Float64} = player_win_chances(curr, past_matches, pa_reck)
        
        finished::Vector{PAMatch} = [setproperties(curr[i], (win_chance = chances[i], alpha = alpha(challenges[i]), beta = beta(challenges[i])))  for i in 1:length(challenges)]

        for i in 1:length(curr)
            add_to_player_hist!(game[i][2], finished[i])
        end
    end

    println("Checkpoint 5: scoring complete")

    LibPQ.execute(conn, "BEGIN;")
    for phist in values(player_hist)
        for row in Tables.rows(phist)
            query = " 
                UPDATE reckoner.armies
                SET alpha = $(alpha(row.challenge)),
                    beta = $(beta(row.challenge)),
                    win_chance = $(row.win_chance)
                WHERE match_id = $(row.match_id)
                AND player_num = $(row.player_num);"
            LibPQ.execute(conn, query)
        end
    end
    LibPQ.execute(conn, "COMMIT;")

    println("Checkpoint 6: committed scores")

    if refresh_view
        LibPQ.execute(conn, "REFRESH MATERIALIZED VIEW reckoner.matchrows_mat;")
    end

    println("Checkpoint 7: refreshed materialized view")
end


function evaluate_matches()
    conn = LibPQ.Connection("dbname=reckoner user=reckoner")
    evaluate_matches(conn)
end

function mass_evaluate_matches()
    conn = LibPQ.Connection("dbname=reckoner user=reckoner")

    query::String = "SELECT COUNT(*) AS count FROM reckoner.matchrows WHERE NOT SCORED;"
    size::Int64 = first(LibPQ.execute(conn, query)).count

    for i in 1:ceil(Int64, size / EVAL_LIMIT)
        evaluate_matches(conn, refresh_view = false)
    end
end
