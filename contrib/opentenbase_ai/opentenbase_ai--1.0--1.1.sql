/* contrib/opentenbase_ai/opentenbase_ai--1.0--1.1.sql */
/* OpenTenBase AI Plugin Caching Enhancement - Upgrade from 1.0 to 1.1 */

-- AI Result Cache Tables

-- Create cache storage table
CREATE TABLE ai.result_cache (
    id BIGSERIAL PRIMARY KEY,
    model_name TEXT NOT NULL,
    args_hash TEXT NOT NULL,           -- Hash of user arguments
    content_hash TEXT,                 -- Hash of result content for similarity
    result_text TEXT NOT NULL,         -- Cached AI model response
    created_time TIMESTAMPTZ NOT NULL DEFAULT now(),
    expiry_time TIMESTAMPTZ NOT NULL,
    last_accessed TIMESTAMPTZ DEFAULT now(),
    access_count INTEGER DEFAULT 1,
    result_size INTEGER DEFAULT 0,     -- Size in bytes for monitoring

    UNIQUE(model_name, args_hash)
) DISTRIBUTE BY HASH(model_name);

-- Create index for efficient lookups
CREATE INDEX idx_result_cache_lookup ON ai.result_cache(model_name, args_hash, expiry_time);
CREATE INDEX idx_result_cache_expiry ON ai.result_cache(expiry_time);
CREATE INDEX idx_result_cache_similarity ON ai.result_cache(model_name, content_hash);

-- Create cache statistics table
CREATE TABLE ai.cache_stats (
    id INTEGER PRIMARY KEY DEFAULT 1,
    total_requests BIGINT DEFAULT 0,
    cache_hits BIGINT DEFAULT 0,
    cache_misses BIGINT DEFAULT 0,
    batch_requests BIGINT DEFAULT 0,
    current_entries INTEGER DEFAULT 0,
    max_entries INTEGER DEFAULT 10000,
    cache_enabled BOOLEAN DEFAULT true,
    last_cleanup TIMESTAMPTZ DEFAULT now(),

    CONSTRAINT single_stats_row CHECK (id = 1)
) DISTRIBUTE BY REPLICATION;

-- Initialize statistics
INSERT INTO ai.cache_stats DEFAULT VALUES ON CONFLICT DO NOTHING;

-- Grant permissions
GRANT SELECT, INSERT, UPDATE, DELETE ON ai.result_cache TO PUBLIC;
GRANT SELECT, UPDATE ON ai.cache_stats TO PUBLIC;

-- Enhanced invoke functions with caching

-- Cached version of invoke_model
CREATE OR REPLACE FUNCTION ai.invoke_model_cached(
    model_name_v TEXT,
    user_args JSONB,
    ttl_seconds INTEGER DEFAULT NULL
)
RETURNS TEXT AS 'MODULE_PATHNAME', 'ai_invoke_model_cached'
LANGUAGE C STRICT;

-- Cached batch processing
CREATE OR REPLACE FUNCTION ai.batch_invoke_cached(
    model_name_v TEXT,
    inputs TEXT[],
    user_args_json TEXT DEFAULT NULL,
    ttl_seconds INTEGER DEFAULT NULL
)
RETURNS TEXT[] AS 'MODULE_PATHNAME', 'ai_batch_invoke_cached'
LANGUAGE C STRICT;

-- Cache management functions

-- Get cache statistics
CREATE OR REPLACE FUNCTION ai.cache_stats()
RETURNS TABLE (
    total_requests BIGINT,
    cache_hits BIGINT,
    cache_misses BIGINT,
    hit_ratio_percent FLOAT8,
    current_entries INTEGER,
    max_entries INTEGER,
    cache_enabled BOOLEAN,
    batch_requests BIGINT
) AS 'MODULE_PATHNAME', 'ai_cache_stats'
LANGUAGE C;

-- Clear cache entries
CREATE OR REPLACE FUNCTION ai.cache_clear(clear_all BOOLEAN DEFAULT false)
RETURNS INTEGER AS 'MODULE_PATHNAME', 'ai_cache_clear'
LANGUAGE C;

-- Convenience wrapper functions

-- Simple cached invoke with default settings
CREATE OR REPLACE FUNCTION ai.ask(model_name TEXT, prompt TEXT)
RETURNS TEXT
LANGUAGE SQL
AS $$
    SELECT ai.invoke_model_cached(
        model_name,
        jsonb_build_object('messages', jsonb_build_array(
            jsonb_build_object('role', 'user', 'content', prompt)
        ))
    );
$$;

-- Cached invoke with custom TTL
CREATE OR REPLACE FUNCTION ai.ask_cached(
    model_name TEXT,
    prompt TEXT,
    ttl_seconds INTEGER DEFAULT 3600
)
RETURNS TEXT
LANGUAGE SQL
AS $$
    SELECT ai.invoke_model_cached(
        model_name,
        jsonb_build_object('messages', jsonb_build_array(
            jsonb_build_object('role', 'user', 'content', prompt)
        )),
        ttl_seconds
    );
$$;

-- Batch processing with caching
CREATE OR REPLACE FUNCTION ai.ask_batch(
    model_name TEXT,
    prompts TEXT[],
    ttl_seconds INTEGER DEFAULT 3600
)
RETURNS TEXT[]
LANGUAGE SQL
AS $$
    SELECT ai.batch_invoke_cached(model_name, prompts, '{}', ttl_seconds);
$$;

-- Enhanced completion function with caching
CREATE OR REPLACE FUNCTION ai.complete_cached(
    prompt TEXT,
    model_name TEXT DEFAULT NULL,
    max_tokens INTEGER DEFAULT 100,
    temperature FLOAT DEFAULT 0.7,
    ttl_seconds INTEGER DEFAULT 3600
)
RETURNS TEXT
LANGUAGE SQL
AS $$
    SELECT ai.invoke_model_cached(
        COALESCE(model_name, current_setting('ai.completion_model', true)),
        jsonb_build_object(
            'messages', jsonb_build_array(
                jsonb_build_object('role', 'user', 'content', prompt)
            ),
            'max_tokens', max_tokens,
            'temperature', temperature
        ),
        ttl_seconds
    );
$$;

-- Enhanced embedding function with caching
CREATE OR REPLACE FUNCTION ai.embed_cached(
    input TEXT,
    model_name TEXT DEFAULT NULL,
    ttl_seconds INTEGER DEFAULT 7200  -- 2 hours for embeddings
)
RETURNS vector
LANGUAGE SQL
AS $$
    SELECT ai.invoke_model_cached(
        COALESCE(model_name, current_setting('ai.embedding_model', true)),
        jsonb_build_object('input', input),
        ttl_seconds
    )::vector;
$$;

-- Cache monitoring views

-- Comprehensive cache statistics view
CREATE OR REPLACE VIEW ai.cache_performance AS
SELECT
    stats.*,
    CASE
        WHEN total_requests > 0
        THEN round((cache_hits * 100.0 / total_requests)::numeric, 2)
        ELSE 0
    END as hit_ratio_calculated,

    CASE
        WHEN max_entries > 0
        THEN round((current_entries * 100.0 / max_entries)::numeric, 2)
        ELSE 0
    END as cache_utilization_percent,

    -- Estimated time and cost savings (assuming 1.5s avg API call, $0.002 per call)
    round((cache_hits * 1.5)::numeric, 2) as estimated_time_saved_seconds,
    round((cache_hits * 0.002)::numeric, 4) as estimated_cost_saved_dollars,

    current_timestamp as stats_time
FROM ai.cache_stats() stats;

GRANT SELECT ON ai.cache_performance TO PUBLIC;

-- Cache entries analysis view
CREATE OR REPLACE VIEW ai.cache_analysis AS
SELECT
    model_name,
    count(*) as entry_count,
    avg(access_count) as avg_access_count,
    max(access_count) as max_access_count,
    avg(result_size) as avg_result_size,
    sum(result_size) as total_size_bytes,
    pg_size_pretty(sum(result_size)) as total_size_pretty,
    min(created_time) as oldest_entry,
    max(created_time) as newest_entry,
    count(CASE WHEN expiry_time > now() THEN 1 END) as active_entries,
    count(CASE WHEN expiry_time <= now() THEN 1 END) as expired_entries
FROM ai.result_cache
GROUP BY model_name
ORDER BY entry_count DESC;

GRANT SELECT ON ai.cache_analysis TO PUBLIC;

-- Cache maintenance functions

-- Automated cache cleanup function
CREATE OR REPLACE FUNCTION ai.cache_maintenance()
RETURNS TEXT
LANGUAGE PLPGSQL
AS $$
DECLARE
    deleted_count INTEGER;
    stats_before RECORD;
    stats_after RECORD;
BEGIN
    -- Get stats before cleanup
    SELECT * INTO stats_before FROM ai.cache_stats() LIMIT 1;

    -- Clean up expired entries
    DELETE FROM ai.result_cache WHERE expiry_time <= now();
    GET DIAGNOSTICS deleted_count = ROW_COUNT;

    -- Update statistics
    UPDATE ai.cache_stats SET
        current_entries = (SELECT count(*) FROM ai.result_cache),
        last_cleanup = now();

    -- Get stats after cleanup
    SELECT * INTO stats_after FROM ai.cache_stats() LIMIT 1;

    RETURN format('Cache maintenance completed. Expired entries removed: %s. '
                  'Entries before: %s, after: %s. Hit ratio: %s%%',
                  deleted_count,
                  stats_before.current_entries,
                  stats_after.current_entries,
                  round(stats_after.hit_ratio_percent, 2));
END;
$$;

-- Cache size management - remove LRU entries if cache is too large
CREATE OR REPLACE FUNCTION ai.cache_evict_lru(target_count INTEGER DEFAULT NULL)
RETURNS INTEGER
LANGUAGE PLPGSQL
AS $$
DECLARE
    current_count INTEGER;
    max_count INTEGER;
    evict_count INTEGER;
    deleted_count INTEGER := 0;
BEGIN
    -- Get current statistics
    SELECT current_entries, max_entries
    INTO current_count, max_count
    FROM ai.cache_stats();

    -- Determine target count
    target_count := COALESCE(target_count, max_count);

    IF current_count <= target_count THEN
        RETURN 0;
    END IF;

    evict_count := current_count - target_count;

    -- Delete least recently used entries
    WITH lru_entries AS (
        SELECT id
        FROM ai.result_cache
        ORDER BY last_accessed ASC, access_count ASC
        LIMIT evict_count
    )
    DELETE FROM ai.result_cache
    WHERE id IN (SELECT id FROM lru_entries);

    GET DIAGNOSTICS deleted_count = ROW_COUNT;

    -- Update statistics
    UPDATE ai.cache_stats SET
        current_entries = (SELECT count(*) FROM ai.result_cache);

    RETURN deleted_count;
END;
$$;

-- Performance testing function
CREATE OR REPLACE FUNCTION ai.cache_benchmark(
    model_name TEXT DEFAULT 'gpt-3.5-turbo',
    test_queries TEXT[] DEFAULT ARRAY[
        'What is artificial intelligence?',
        'Explain machine learning',
        'What are neural networks?',
        'Define deep learning',
        'What is natural language processing?'
    ]
)
RETURNS TABLE (
    phase TEXT,
    execution_time_ms INTEGER,
    cache_hits_before BIGINT,
    cache_hits_after BIGINT,
    hit_ratio_percent FLOAT8
)
LANGUAGE PLPGSQL
AS $$
DECLARE
    start_time TIMESTAMPTZ;
    end_time TIMESTAMPTZ;
    stats_before RECORD;
    stats_after RECORD;
    query TEXT;
    result TEXT;
BEGIN
    -- Phase 1: First run (cache misses expected)
    SELECT * INTO stats_before FROM ai.cache_stats() LIMIT 1;
    start_time := clock_timestamp();

    FOREACH query IN ARRAY test_queries LOOP
        SELECT ai.ask_cached(model_name, query, 3600) INTO result;
    END LOOP;

    end_time := clock_timestamp();
    SELECT * INTO stats_after FROM ai.cache_stats() LIMIT 1;

    RETURN QUERY SELECT
        'First Run (Cache Miss)'::TEXT,
        extract(milliseconds FROM (end_time - start_time))::INTEGER,
        stats_before.cache_hits,
        stats_after.cache_hits,
        CASE WHEN stats_after.total_requests > 0
             THEN (stats_after.cache_hits * 100.0 / stats_after.total_requests)::FLOAT8
             ELSE 0::FLOAT8 END;

    -- Small delay
    PERFORM pg_sleep(0.1);

    -- Phase 2: Second run (cache hits expected)
    stats_before := stats_after;
    start_time := clock_timestamp();

    FOREACH query IN ARRAY test_queries LOOP
        SELECT ai.ask_cached(model_name, query, 3600) INTO result;
    END LOOP;

    end_time := clock_timestamp();
    SELECT * INTO stats_after FROM ai.cache_stats() LIMIT 1;

    RETURN QUERY SELECT
        'Second Run (Cache Hit)'::TEXT,
        extract(milliseconds FROM (end_time - start_time))::INTEGER,
        stats_before.cache_hits,
        stats_after.cache_hits,
        CASE WHEN stats_after.total_requests > 0
             THEN (stats_after.cache_hits * 100.0 / stats_after.total_requests)::FLOAT8
             ELSE 0::FLOAT8 END;
END;
$$;

-- Add comments for documentation
COMMENT ON TABLE ai.result_cache IS
    'Stores cached AI model results to improve performance by avoiding repeated API calls';

COMMENT ON TABLE ai.cache_stats IS
    'Maintains statistics about AI result cache performance and usage';

COMMENT ON FUNCTION ai.invoke_model_cached(TEXT, JSONB, INTEGER) IS
    'Enhanced version of invoke_model with intelligent result caching support';

COMMENT ON FUNCTION ai.ask(TEXT, TEXT) IS
    'Simple AI query interface with automatic caching enabled';

COMMENT ON FUNCTION ai.cache_maintenance() IS
    'Performs maintenance tasks like cleaning expired cache entries';

COMMENT ON VIEW ai.cache_performance IS
    'Real-time view of cache performance metrics with calculated ratios and savings estimates';

-- Create a sample usage demonstration
CREATE OR REPLACE FUNCTION ai.demo_cache_performance()
RETURNS TABLE (
    demo_step TEXT,
    description TEXT,
    execution_time_ms INTEGER,
    result_preview TEXT
)
LANGUAGE PLPGSQL
AS $$
DECLARE
    start_time TIMESTAMPTZ;
    end_time TIMESTAMPTZ;
    test_prompt TEXT := 'What are the key benefits of database indexing?';
    result1 TEXT;
    result2 TEXT;
BEGIN
    -- Step 1: Clear cache for clean test
    PERFORM ai.cache_clear(true);

    RETURN QUERY SELECT
        'Setup'::TEXT,
        'Cache cleared for clean performance test'::TEXT,
        0,
        'Cache is now empty'::TEXT;

    -- Step 2: First call (cache miss)
    start_time := clock_timestamp();
    SELECT ai.ask_cached('gpt-3.5-turbo', test_prompt, 3600) INTO result1;
    end_time := clock_timestamp();

    RETURN QUERY SELECT
        'First Call'::TEXT,
        'Cache miss - calls external API'::TEXT,
        extract(milliseconds FROM (end_time - start_time))::INTEGER,
        substring(result1, 1, 50) || '...'::TEXT;

    -- Step 3: Second call (cache hit)
    start_time := clock_timestamp();
    SELECT ai.ask_cached('gpt-3.5-turbo', test_prompt, 3600) INTO result2;
    end_time := clock_timestamp();

    RETURN QUERY SELECT
        'Second Call'::TEXT,
        'Cache hit - returns cached result instantly'::TEXT,
        extract(milliseconds FROM (end_time - start_time))::INTEGER,
        substring(result2, 1, 50) || '...'::TEXT;

    -- Step 4: Show performance improvement
    RETURN QUERY
    WITH perf_stats AS (
        SELECT * FROM ai.cache_performance LIMIT 1
    )
    SELECT
        'Performance Summary'::TEXT,
        format('Hit ratio: %s%%, Time saved: %ss, Cost saved: $%s',
               round(hit_ratio_percent, 1),
               estimated_time_saved_seconds,
               estimated_cost_saved_dollars)::TEXT,
        0,
        format('Cache entries: %s/%s', current_entries, max_entries)::TEXT
    FROM perf_stats;
END;
$$;

-- Final setup: Update version
UPDATE ai.cache_stats SET cache_enabled = true WHERE id = 1;