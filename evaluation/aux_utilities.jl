include("reckonerPA_equations.jl")

const PlayerHist = Dict{PlayerId, PAMatches}

function gen_locus(template::PAMatch, teams::Vector{Int64})::Vector{PAMatch}
    n::Int64 = length(teams)
    output::Vector{PAMatch} = Vector{PAMatch}(undef, n)

    for i in 1:n
        output[i] = @set template.team_id = teams[i]
    end

    output
end

function gen_past(locus::Vector{PAMatch}, prev::PAMatches)::Vector{PAMatches}
    default::PAMatches = aup(locus[1], pa_reck)

    n = length(locus)

    output::Vector{PAMatches} = [default for i in 1:n]

    output[1] = merge(output[1], prev)

    output
end

function empty_matches()::PAMatches 
    PAMatches(
        Vector{Float64}(),
        Vector{Beta{Float64}}(),
        Vector{Int64}(),
        Vector{Bool}(),
        Vector{Int16}(),
        Vector{Float64}(),
        Vector{Float64}(),
        Vector{Int16}(),
        Vector{Int64}(),
        Vector{Float64}(),
        Vector{Float64}(),
        Vector{Float64}(),
        Vector{Bool}(),
        Vector{Bool}(),
        Vector{Bool}(),
        Vector{Bool}(),
        Vector{Bool}(),
        Vector{Bool}(),
        Vector{Int16}(),
        Vector{Float64}()
    )
end


function get_player_matches(player_ids::Vector, conn, player_types::Vector{String})::PlayerHist
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
            player_num,
            alpha,
            beta,
            rating_sd
        FROM reckoner.matchrows_mat
        WHERE SCORED
        AND (player_type, player_id) IN ("
    for (type, id) in zip(player_types, player_ids)
        query *= "('$(sanitize(type))','$(sanitize(id))'),"
    end
    query = query[1:end-1] * ");"
    # query = query[1:end-1] * ") ORDER BY TIME_START ASC;"
    res = LibPQ.execute(conn, query)

    player_hist::PlayerHist = PlayerHist()

    for (type, id) in zip(player_types, player_ids)
        pid::PlayerId = (type, string(id))
        player_hist[pid] = empty_matches()
    end

    for row in res
        pid::PlayerId = (row.player_type, row.player_id)
        if pid in keys(player_hist)
            push!(player_hist[pid], row |> PAMatch)
        else
            player_hist[pid] = PAMatches([PAMatch(row)])
        end
    end
    
    player_hist
end

function get_player_matches(player_ids::Vector{UInt64}, conn)::PlayerHist
    player_types = ["pa inc" for i in player_ids]
    get_player_matches(player_ids, conn, player_types)
end


function get_player_matches(uberid::Any, conn, player_type = "pa inc")::PlayerHist
   get_player_matches([uberid], conn, [player_type])
end