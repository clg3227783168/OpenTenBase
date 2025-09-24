#include "postgres.h"
#include "utils/guc.h"
#include "utils/memutils.h"
#include "utils/builtins.h"
#include "executor/spi.h"
#include "funcapi.h"
#include "access/htup_details.h"
#include "utils/jsonb.h"
#include "fmgr.h"
#include "miscadmin.h"
#include <curl/curl.h>
#include <pthread.h>

PG_MODULE_MAGIC;

/* Configuration variables */
static char *default_completion_model = NULL;
static char *default_embedding_model = NULL;
static char *default_image_model = NULL;
static int batch_size = 10;
static int batch_timeout_ms = 500;
static int max_concurrent_requests = 50;
static bool enable_batch_processing = true;

/* Batch processing structures */
typedef struct BatchRequest {
    int request_id;
    char *model_name;
    char *input_data;
    char *user_args_json;
    bool completed;
    char *result;
    char *error_msg;
    struct BatchRequest *next;
} BatchRequest;

typedef struct BatchContext {
    BatchRequest *requests;
    int request_count;
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    bool processing;
    TimestampTz created_at;
} BatchContext;

/* HTTP response structure for libcurl */
typedef struct {
    char *data;
    size_t size;
} HttpResponse;

/* Global batch context */
static BatchContext *global_batch_ctx = NULL;
static pthread_t batch_processor_thread;

/* Function declarations */
void _PG_init(void);
void _PG_fini(void);
static void* batch_processor(void *arg);
static size_t WriteCallback(void *contents, size_t size, size_t nmemb, HttpResponse *response);
static void process_batch_requests(BatchRequest *requests, int count);
static void init_batch_context(void);
static void cleanup_batch_context(void);

PG_FUNCTION_INFO_V1(ai_batch_invoke);
PG_FUNCTION_INFO_V1(ai_configure_batch);

/* libcurl write callback */
static size_t WriteCallback(void *contents, size_t size, size_t nmemb, HttpResponse *response)
{
    size_t total_size = size * nmemb;
    char *temp = realloc(response->data, response->size + total_size + 1);

    if (temp == NULL) {
        return 0; /* Out of memory */
    }

    response->data = temp;
    memcpy(&(response->data[response->size]), contents, total_size);
    response->size += total_size;
    response->data[response->size] = 0;

    return total_size;
}

/* Process batch requests using libcurl multi interface */
static void process_batch_requests(BatchRequest *requests, int count)
{
    CURLM *multi_handle;
    CURL *curl_handles[count];
    HttpResponse responses[count];
    int still_running = 0;
    int i;

    /* Initialize libcurl multi handle */
    multi_handle = curl_multi_init();

    /* Set up individual curl handles */
    for (i = 0; i < count; i++) {
        BatchRequest *req = &requests[i];

        curl_handles[i] = curl_easy_init();
        responses[i].data = malloc(1);
        responses[i].size = 0;

        if (curl_handles[i]) {
            /* Get model configuration from database */
            char query[1024];
            snprintf(query, sizeof(query),
                "SELECT uri, request_header, content_type, default_args FROM public.ai_model_list WHERE model_name = '%s'",
                req->model_name);

            /* Execute SQL to get model config - simplified for demo */
            /* In real implementation, use SPI_execute here */

            /* For demo, assume we have the URL */
            curl_easy_setopt(curl_handles[i], CURLOPT_URL, "https://api.example.com/v1/completions");
            curl_easy_setopt(curl_handles[i], CURLOPT_POSTFIELDS, req->input_data);
            curl_easy_setopt(curl_handles[i], CURLOPT_WRITEFUNCTION, WriteCallback);
            curl_easy_setopt(curl_handles[i], CURLOPT_WRITEDATA, &responses[i]);
            curl_easy_setopt(curl_handles[i], CURLOPT_TIMEOUT, 30);

            /* Add to multi handle */
            curl_multi_add_handle(multi_handle, curl_handles[i]);
        }
    }

    /* Perform all HTTP requests */
    curl_multi_perform(multi_handle, &still_running);

    /* Wait for completion */
    while (still_running) {
        struct timeval timeout = {1, 0}; /* 1 second timeout */
        int rc;

        fd_set fdread, fdwrite, fdexcep;
        int maxfd = -1;

        FD_ZERO(&fdread);
        FD_ZERO(&fdwrite);
        FD_ZERO(&fdexcep);

        curl_multi_fdset(multi_handle, &fdread, &fdwrite, &fdexcep, &maxfd);

        rc = select(maxfd + 1, &fdread, &fdwrite, &fdexcep, &timeout);

        if (rc == -1) {
            break;
        }

        curl_multi_perform(multi_handle, &still_running);
    }

    /* Store results */
    for (i = 0; i < count; i++) {
        BatchRequest *req = &requests[i];
        req->result = responses[i].data;
        req->completed = true;

        /* Cleanup */
        curl_multi_remove_handle(multi_handle, curl_handles[i]);
        curl_easy_cleanup(curl_handles[i]);
    }

    curl_multi_cleanup(multi_handle);
}

/* Batch processor thread */
static void* batch_processor(void *arg)
{
    BatchContext *ctx = (BatchContext*)arg;

    while (true) {
        pthread_mutex_lock(&ctx->mutex);

        /* Wait for requests or timeout */
        struct timespec timeout;
        clock_gettime(CLOCK_REALTIME, &timeout);
        timeout.tv_nsec += batch_timeout_ms * 1000000;
        if (timeout.tv_nsec >= 1000000000) {
            timeout.tv_sec += 1;
            timeout.tv_nsec -= 1000000000;
        }

        int wait_result = pthread_cond_timedwait(&ctx->condition, &ctx->mutex, &timeout);

        /* Process batch if we have requests */
        if (ctx->request_count > 0 &&
            (ctx->request_count >= batch_size || wait_result == ETIMEDOUT)) {

            ctx->processing = true;

            /* Convert linked list to array for processing */
            BatchRequest *req_array = malloc(ctx->request_count * sizeof(BatchRequest));
            BatchRequest *current = ctx->requests;
            int i = 0;

            while (current && i < ctx->request_count) {
                req_array[i] = *current;
                current = current->next;
                i++;
            }

            pthread_mutex_unlock(&ctx->mutex);

            /* Process batch */
            process_batch_requests_enhanced(req_array, ctx->request_count);

            pthread_mutex_lock(&ctx->mutex);

            /* Mark processing complete */
            ctx->processing = false;
            ctx->request_count = 0;
            ctx->requests = NULL;

            free(req_array);

            /* Signal completion */
            pthread_cond_broadcast(&ctx->condition);
        }

        pthread_mutex_unlock(&ctx->mutex);
    }

    return NULL;
}

/* Initialize batch processing context */
static void init_batch_context(void)
{
    global_batch_ctx = malloc(sizeof(BatchContext));
    global_batch_ctx->requests = NULL;
    global_batch_ctx->request_count = 0;
    global_batch_ctx->processing = false;
    global_batch_ctx->created_at = GetCurrentTimestamp();

    pthread_mutex_init(&global_batch_ctx->mutex, NULL);
    pthread_cond_init(&global_batch_ctx->condition, NULL);

    /* Start batch processor thread */
    pthread_create(&batch_processor_thread, NULL, batch_processor, global_batch_ctx);
}

/* Cleanup batch processing context */
static void cleanup_batch_context(void)
{
    if (global_batch_ctx) {
        pthread_cancel(batch_processor_thread);
        pthread_join(batch_processor_thread, NULL);

        pthread_mutex_destroy(&global_batch_ctx->mutex);
        pthread_cond_destroy(&global_batch_ctx->condition);

        free(global_batch_ctx);
        global_batch_ctx = NULL;
    }
}

void _PG_init(void)
{
    DefineCustomStringVariable(
        "ai.completion_model",
        "Sets the default AI completion model to use",
        "This parameter specifies which AI model will be used by default for text completions.",
        &default_completion_model,
        NULL,
        PGC_USERSET,
        0,
        NULL,
        NULL,
        NULL
    );

    DefineCustomStringVariable(
        "ai.embedding_model",
        "Sets the default AI embedding model to use",
        "This parameter specifies which AI model will be used by default for embeddings.",
        &default_embedding_model,
        NULL,
        PGC_USERSET,
        0,
        NULL,
        NULL,
        NULL
    );

    DefineCustomStringVariable(
        "ai.image_model",
        "Sets the default AI image model to use",
        "This parameter specifies which AI model will be used by default for image analysis.",
        &default_image_model,
        NULL,
        PGC_USERSET,
        0,
        NULL,
        NULL,
        NULL
    );

    DefineCustomIntVariable(
        "ai.batch_size",
        "Sets the batch size for AI model calls",
        "Number of requests to batch together for processing.",
        &batch_size,
        10,
        1, 100,
        PGC_USERSET,
        0,
        NULL,
        NULL,
        NULL
    );

    DefineCustomIntVariable(
        "ai.batch_timeout_ms",
        "Sets the batch timeout in milliseconds",
        "Maximum time to wait before processing a batch.",
        &batch_timeout_ms,
        500,
        100, 5000,
        PGC_USERSET,
        0,
        NULL,
        NULL,
        NULL
    );

    DefineCustomBoolVariable(
        "ai.enable_batch_processing",
        "Enable batch processing for AI calls",
        "When enabled, AI calls will be batched for better performance.",
        &enable_batch_processing,
        true,
        PGC_USERSET,
        0,
        NULL,
        NULL,
        NULL
    );

    /* Initialize libcurl */
    curl_global_init(CURL_GLOBAL_DEFAULT);

    /* Initialize batch processing */
    if (enable_batch_processing) {
        init_batch_context();
    }
}

/* Batch invoke function - main entry point for batch processing */
Datum ai_batch_invoke(PG_FUNCTION_ARGS)
{
    text *model_name_text = PG_GETARG_TEXT_PP(0);
    text *input_data_text = PG_GETARG_TEXT_PP(1);
    text *user_args_text = PG_ARGISNULL(2) ? NULL : PG_GETARG_TEXT_PP(2);

    char *model_name = text_to_cstring(model_name_text);
    char *input_data = text_to_cstring(input_data_text);
    char *user_args = user_args_text ? text_to_cstring(user_args_text) : "{}";

    if (!enable_batch_processing || global_batch_ctx == NULL) {
        /* Fall back to single request processing */
        elog(INFO, "Batch processing disabled, falling back to single request");
        PG_RETURN_NULL();
    }

    /* Create new batch request */
    BatchRequest *new_request = malloc(sizeof(BatchRequest));
    new_request->request_id = rand(); /* Simple ID generation */
    new_request->model_name = strdup(model_name);
    new_request->input_data = strdup(input_data);
    new_request->user_args_json = strdup(user_args);
    new_request->completed = false;
    new_request->result = NULL;
    new_request->error_msg = NULL;
    new_request->next = NULL;

    /* Add request to batch queue */
    pthread_mutex_lock(&global_batch_ctx->mutex);

    /* Add to linked list */
    if (global_batch_ctx->requests == NULL) {
        global_batch_ctx->requests = new_request;
    } else {
        BatchRequest *current = global_batch_ctx->requests;
        while (current->next != NULL) {
            current = current->next;
        }
        current->next = new_request;
    }

    global_batch_ctx->request_count++;

    /* Signal batch processor if we've reached batch size */
    if (global_batch_ctx->request_count >= batch_size) {
        pthread_cond_signal(&global_batch_ctx->condition);
    }

    pthread_mutex_unlock(&global_batch_ctx->mutex);

    /* Wait for processing completion */
    struct timespec timeout;
    clock_gettime(CLOCK_REALTIME, &timeout);
    timeout.tv_sec += 30; /* 30 second timeout */

    pthread_mutex_lock(&global_batch_ctx->mutex);

    while (!new_request->completed && !global_batch_ctx->processing) {
        int wait_result = pthread_cond_timedwait(&global_batch_ctx->condition,
                                                &global_batch_ctx->mutex, &timeout);

        if (wait_result == ETIMEDOUT) {
            pthread_mutex_unlock(&global_batch_ctx->mutex);
            elog(ERROR, "Batch processing timeout");
            PG_RETURN_NULL();
        }
    }

    /* Get result */
    char *result = NULL;
    if (new_request->completed && new_request->result) {
        result = strdup(new_request->result);
    }

    pthread_mutex_unlock(&global_batch_ctx->mutex);

    /* Cleanup */
    free(new_request->model_name);
    free(new_request->input_data);
    free(new_request->user_args_json);
    if (new_request->result) free(new_request->result);
    if (new_request->error_msg) free(new_request->error_msg);
    free(new_request);

    if (result) {
        text *result_text = cstring_to_text(result);
        free(result);
        PG_RETURN_TEXT_P(result_text);
    }

    PG_RETURN_NULL();
}

/* Configure batch processing parameters */
Datum ai_configure_batch(PG_FUNCTION_ARGS)
{
    text *param_name_text = PG_GETARG_TEXT_PP(0);
    int32 param_value = PG_GETARG_INT32(1);

    char *param_name = text_to_cstring(param_name_text);

    if (strcmp(param_name, "batch_size") == 0) {
        if (param_value >= 1 && param_value <= 100) {
            batch_size = param_value;
            elog(INFO, "Batch size set to %d", batch_size);
        } else {
            elog(ERROR, "Batch size must be between 1 and 100");
        }
    } else if (strcmp(param_name, "batch_timeout_ms") == 0) {
        if (param_value >= 100 && param_value <= 5000) {
            batch_timeout_ms = param_value;
            elog(INFO, "Batch timeout set to %d ms", batch_timeout_ms);
        } else {
            elog(ERROR, "Batch timeout must be between 100 and 5000 ms");
        }
    } else if (strcmp(param_name, "max_concurrent_requests") == 0) {
        if (param_value >= 1 && param_value <= 200) {
            max_concurrent_requests = param_value;
            elog(INFO, "Max concurrent requests set to %d", max_concurrent_requests);
        } else {
            elog(ERROR, "Max concurrent requests must be between 1 and 200");
        }
    } else {
        elog(ERROR, "Unknown parameter: %s", param_name);
    }

    pfree(param_name);
    PG_RETURN_BOOL(true);
}

/* Enhanced batch processing with SPI integration */
static void process_batch_requests_enhanced(BatchRequest *requests, int count)
{
    CURLM *multi_handle;
    CURL *curl_handles[count];
    HttpResponse responses[count];
    int still_running = 0;
    int i;

    /* Connect to SPI for database access */
    if (SPI_connect() != SPI_OK_CONNECT) {
        elog(ERROR, "SPI_connect failed");
        return;
    }

    /* Initialize libcurl multi handle */
    multi_handle = curl_multi_init();

    /* Set up individual curl handles */
    for (i = 0; i < count; i++) {
        BatchRequest *req = &requests[i];

        curl_handles[i] = curl_easy_init();
        responses[i].data = malloc(1);
        responses[i].size = 0;

        if (curl_handles[i]) {
            /* Get model configuration from database using SPI */
            char query[1024];
            int ret;
            uint64 proc;

            snprintf(query, sizeof(query),
                "SELECT uri, request_header, content_type, default_args, request_type "
                "FROM public.ai_model_list WHERE model_name = '%s'",
                req->model_name);

            ret = SPI_execute(query, true, 1);

            if (ret == SPI_OK_SELECT && SPI_processed == 1) {
                /* Extract model configuration */
                HeapTuple tuple = SPI_tuptable->vals[0];
                TupleDesc tupdesc = SPI_tuptable->tupdesc;

                bool isnull;
                char *uri = SPI_getvalue(tuple, tupdesc, 1);
                char *content_type = SPI_getvalue(tuple, tupdesc, 3);
                char *default_args = SPI_getvalue(tuple, tupdesc, 4);
                char *request_type = SPI_getvalue(tuple, tupdesc, 5);

                /* Merge user args with default args */
                char merged_args[2048];
                snprintf(merged_args, sizeof(merged_args),
                    "{\"prompt\": \"%s\", %s}",
                    req->input_data,
                    req->user_args_json + 1); /* Skip opening brace */

                /* Configure curl handle */
                curl_easy_setopt(curl_handles[i], CURLOPT_URL, uri);

                if (strcmp(request_type, "POST") == 0) {
                    curl_easy_setopt(curl_handles[i], CURLOPT_POSTFIELDS, merged_args);
                }

                curl_easy_setopt(curl_handles[i], CURLOPT_WRITEFUNCTION, WriteCallback);
                curl_easy_setopt(curl_handles[i], CURLOPT_WRITEDATA, &responses[i]);
                curl_easy_setopt(curl_handles[i], CURLOPT_TIMEOUT, 30);

                /* Set headers */
                struct curl_slist *headers = NULL;
                char content_type_header[256];
                snprintf(content_type_header, sizeof(content_type_header),
                         "Content-Type: %s", content_type);
                headers = curl_slist_append(headers, content_type_header);
                curl_easy_setopt(curl_handles[i], CURLOPT_HTTPHEADER, headers);

                /* Add to multi handle */
                curl_multi_add_handle(multi_handle, curl_handles[i]);

                /* Cleanup SPI results */
                if (uri) pfree(uri);
                if (content_type) pfree(content_type);
                if (default_args) pfree(default_args);
                if (request_type) pfree(request_type);
            } else {
                elog(WARNING, "Model %s not found in database", req->model_name);
                req->error_msg = strdup("Model not found");
                req->completed = true;
            }
        }
    }

    SPI_finish();

    /* Perform all HTTP requests concurrently */
    curl_multi_perform(multi_handle, &still_running);

    /* Wait for completion with proper event handling */
    while (still_running) {
        struct timeval timeout = {1, 0}; /* 1 second timeout */
        int rc;

        fd_set fdread, fdwrite, fdexcep;
        int maxfd = -1;

        FD_ZERO(&fdread);
        FD_ZERO(&fdwrite);
        FD_ZERO(&fdexcep);

        curl_multi_fdset(multi_handle, &fdread, &fdwrite, &fdexcep, &maxfd);

        rc = select(maxfd + 1, &fdread, &fdwrite, &fdexcep, &timeout);

        if (rc == -1) {
            break;
        }

        curl_multi_perform(multi_handle, &still_running);
    }

    /* Store results and cleanup */
    for (i = 0; i < count; i++) {
        BatchRequest *req = &requests[i];

        if (!req->completed) {
            req->result = responses[i].data;
            req->completed = true;
        }

        /* Cleanup curl handles */
        curl_multi_remove_handle(multi_handle, curl_handles[i]);
        curl_easy_cleanup(curl_handles[i]);
    }

    curl_multi_cleanup(multi_handle);
}

void _PG_fini(void)
{
    cleanup_batch_context();
    curl_global_cleanup();
}
