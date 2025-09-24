# OpenTenBase AI 批量处理 - 快速开始指南

## 快速部署

### 1. 编译安装
```bash
# 确保已安装依赖
sudo yum install -y libcurl-devel pthread

# 编译安装插件
cd contrib/opentenbase_ai
make clean && make install

# 重启OpenTenBase
sudo systemctl restart opentenbase
```

### 2. 启用功能
```sql
-- 连接到数据库
psql -h your_coordinator -p 11000 -U opentenbase postgres

-- 创建扩展
CREATE EXTENSION IF NOT EXISTS http;
CREATE EXTENSION opentenbase_ai;

-- 配置批量处理
SELECT ai.configure_batch('batch_size', 10);
SELECT ai.configure_batch('batch_timeout_ms', 500);
```

### 3. 添加AI模型
```sql
-- 添加OpenAI GPT模型
SELECT ai.add_completion_model(
    'gpt-3.5-turbo',
    'https://api.openai.com/v1/chat/completions',
    '{"model": "gpt-3.5-turbo", "temperature": 0.7}'::jsonb,
    'your-openai-api-key',
    'openai'
);
```

## 核心使用方法

### 批量文本处理
```sql
-- 方法1: 直接批量调用
SELECT ai.batch_invoke('gpt-3.5-turbo', 'Summarize this text', '{}'::jsonb);

-- 方法2: 数组批量处理
SELECT ai.batch_completion(
    ARRAY['Text 1', 'Text 2', 'Text 3'],
    'gpt-3.5-turbo'
);

-- 方法3: 表级批量处理
SELECT ai.process_table_batch(
    'articles',      -- 表名
    'content',       -- 输入列
    'gpt-3.5-turbo', -- 模型
    'summary'        -- 输出列
);
```

### 性能监控
```sql
-- 查看配置状态
SELECT * FROM ai.batch_status();

-- 调整批量参数
SELECT ai.configure_batch('batch_size', 20);  -- 增大批量
```

## 预期性能提升
- **响应时间**：提升 100-300%
- **吞吐量**：每秒处理更多请求
- **资源效率**：CPU利用率提升，内存占用减少

启用批量处理后，OpenTenBase_AI 将自动优化多个AI调用，显著提升大模型集成的执行效率！