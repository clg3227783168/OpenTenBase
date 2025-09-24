-- Test setup
CREATE EXTENSION IF NOT EXISTS http;
CREATE EXTENSION IF NOT EXISTS opentenbase_ai;

-- Test 1: Check if extension is properly loaded
SELECT count(*) > 0 AS extension_loaded FROM pg_extension WHERE extname = 'opentenbase_ai';

-- Test 2: Check if schema and tables are created correctly
SELECT count(*) > 0 AS model_list_exists
FROM pg_tables
WHERE schemaname = 'public' AND tablename = 'ai_model_list';

-- Test 3: Add a test model for batch processing
SELECT ai.add_completion_model(
    'test_batch_model',
    'https://httpbin.org/post',
    '{"model": "gpt-4", "temperature": 0.7, "max_tokens": 100}'::jsonb,
    'test-token-123',
    'openai'
);

-- Test 4: Test batch processing configuration
SELECT ai.configure_batch('batch_size', 5);
SELECT ai.configure_batch('batch_timeout_ms', 1000);

-- Test 5: Check batch status
SELECT * FROM ai.batch_status();

-- Test 6: Test single batch invoke (basic functionality)
SELECT length(ai.batch_invoke('test_batch_model', 'Hello world', '{"temperature": 0.5}'::jsonb)) > 0 AS batch_invoke_works;

-- Test 7: Test batch completion with array input
SELECT array_length(ai.batch_completion(
    ARRAY['Hello', 'World', 'Test batch processing'],
    'test_batch_model',
    '{"temperature": 0.3}'::jsonb
), 1) = 3 AS batch_completion_array_works;

-- Test 8: Create test table for table batch processing
CREATE TABLE test_articles (
    id SERIAL PRIMARY KEY,
    title TEXT,
    content TEXT
) DISTRIBUTE BY HASH(id);

-- Insert test data
INSERT INTO test_articles (title, content) VALUES
    ('Article 1', 'This is the content of article 1 for testing batch processing.'),
    ('Article 2', 'This is the content of article 2 for testing batch processing.'),
    ('Article 3', 'This is the content of article 3 for testing batch processing.'),
    ('Article 4', 'This is the content of article 4 for testing batch processing.'),
    ('Article 5', 'This is the content of article 5 for testing batch processing.');

-- Test 9: Test table batch processing
SELECT ai.process_table_batch(
    'test_articles',
    'content',
    'test_batch_model',
    'summary',
    3  -- batch_size
) AS processed_rows;

-- Test 10: Verify batch processing results
SELECT count(*) AS articles_with_summaries
FROM test_articles
WHERE summary IS NOT NULL AND summary != '';

-- Test 11: Test batch processing with WHERE clause
INSERT INTO test_articles (title, content) VALUES
    ('Special Article', 'This article should be processed separately.');

SELECT ai.process_table_batch(
    'test_articles',
    'content',
    'test_batch_model',
    'special_summary',
    2,
    "title LIKE '%Special%'"
) AS special_processed_rows;

-- Test 12: Test error handling for invalid model
SELECT ai.batch_invoke('non_existent_model', 'test input', '{}'::jsonb);

-- Test 13: Test batch configuration limits
SELECT ai.configure_batch('batch_size', 200); -- Should fail (too high)
SELECT ai.configure_batch('batch_timeout_ms', 50); -- Should fail (too low)

-- Test 14: Test concurrent batch processing simulation
-- Create multiple batch requests
CREATE OR REPLACE FUNCTION test_concurrent_batch() RETURNS boolean AS $$
DECLARE
    i integer;
    results text[];
BEGIN
    -- Generate multiple concurrent requests
    FOR i IN 1..15 LOOP
        results := array_append(results,
            ai.batch_invoke('test_batch_model',
                           'Concurrent test ' || i::text,
                           '{"temperature": 0.1}'::jsonb));
    END LOOP;

    -- Check if we got results
    RETURN array_length(results, 1) = 15;
END;
$$ LANGUAGE plpgsql;

SELECT test_concurrent_batch() AS concurrent_batch_test_passed;

-- Test 15: Performance comparison test
-- Create performance test function
CREATE OR REPLACE FUNCTION test_performance_comparison() RETURNS table(
    method text,
    duration interval,
    requests_per_second float
) AS $$
DECLARE
    start_time timestamp;
    end_time timestamp;
    single_duration interval;
    batch_duration interval;
    test_inputs text[] := ARRAY['Test 1', 'Test 2', 'Test 3', 'Test 4', 'Test 5'];
    result_single text[];
    result_batch text[];
    input_text text;
BEGIN
    -- Test single requests
    start_time := clock_timestamp();
    FOREACH input_text IN ARRAY test_inputs LOOP
        result_single := array_append(result_single,
                                    ai.invoke_model('test_batch_model',
                                                  '{"prompt": "' || input_text || '"}'::jsonb));
    END LOOP;
    end_time := clock_timestamp();
    single_duration := end_time - start_time;

    -- Test batch requests
    start_time := clock_timestamp();
    result_batch := ai.batch_completion(test_inputs, 'test_batch_model', '{}'::jsonb);
    end_time := clock_timestamp();
    batch_duration := end_time - start_time;

    -- Return results
    RETURN QUERY VALUES
        ('single_requests'::text, single_duration, 5.0 / EXTRACT(EPOCH FROM single_duration)),
        ('batch_requests'::text, batch_duration, 5.0 / EXTRACT(EPOCH FROM batch_duration));
END;
$$ LANGUAGE plpgsql;

-- Run performance comparison
SELECT * FROM test_performance_comparison();

-- Test 16: Test batch processing with different data types
CREATE TABLE test_mixed_data (
    id SERIAL PRIMARY KEY,
    text_data TEXT,
    json_data JSONB,
    numeric_data NUMERIC
) DISTRIBUTE BY HASH(id);

INSERT INTO test_mixed_data (text_data, json_data, numeric_data) VALUES
    ('Sample text 1', '{"key": "value1"}'::jsonb, 123.45),
    ('Sample text 2', '{"key": "value2"}'::jsonb, 678.90),
    ('Sample text 3', '{"key": "value3"}'::jsonb, 999.99);

-- Test batch processing on mixed data
SELECT ai.process_table_batch(
    'test_mixed_data',
    'text_data',
    'test_batch_model',
    'ai_analysis',
    2
) AS mixed_data_processed;

-- Test 17: Clean up test data
DROP TABLE IF EXISTS test_articles;
DROP TABLE IF EXISTS test_mixed_data;
DROP FUNCTION IF EXISTS test_concurrent_batch();
DROP FUNCTION IF EXISTS test_performance_comparison();

-- Test 18: Delete test model
SELECT ai.delete_model('test_batch_model');

-- Test 19: Verify cleanup
SELECT count(*) = 0 AS all_test_models_deleted
FROM ai_model_list
WHERE model_name = 'test_batch_model';

-- Final cleanup
DROP EXTENSION IF EXISTS opentenbase_ai CASCADE;
DROP EXTENSION IF EXISTS http;
