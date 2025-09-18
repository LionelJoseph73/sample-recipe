-- File: database_schema.sql
-- PostgreSQL Database Schema for Sign Recipe Generator

-- Create database
CREATE DATABASE signrecipes;

-- Connect to the database
\c signrecipes;

-- Enable UUID extension for session IDs
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Products table
CREATE TABLE products (
    id SERIAL PRIMARY KEY,
    product_code VARCHAR(50) UNIQUE NOT NULL,
    product_name VARCHAR(255) NOT NULL,
    category VARCHAR(100),
    core_capability BOOLEAN DEFAULT FALSE,
    outsourced BOOLEAN DEFAULT FALSE,
    assigned_recipe VARCHAR(255),
    short_description TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create index for faster searches
CREATE INDEX idx_products_name ON products(product_name);
CREATE INDEX idx_products_category ON products(category);
CREATE INDEX idx_products_code ON products(product_code);

-- Materials table
CREATE TABLE materials (
    id SERIAL PRIMARY KEY,
    partcode VARCHAR(50) UNIQUE NOT NULL,
    friendly_description VARCHAR(255) NOT NULL,
    base VARCHAR(20),
    sub VARCHAR(20),
    thk DECIMAL(8,2),
    grd VARCHAR(20),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create index for materials
CREATE INDEX idx_materials_partcode ON materials(partcode);
CREATE INDEX idx_materials_base ON materials(base);
CREATE INDEX idx_materials_description ON materials(friendly_description);

-- Processes table
CREATE TABLE processes (
    id SERIAL PRIMARY KEY,
    sort_id INTEGER,
    parent_id INTEGER DEFAULT 0,
    proc_code VARCHAR(50) UNIQUE NOT NULL,
    proc_name VARCHAR(255) NOT NULL,
    discipline VARCHAR(100),
    input_form VARCHAR(255),
    output_form VARCHAR(255),
    key_tools VARCHAR(255),
    setup_time_min DECIMAL(8,2) DEFAULT 0,
    run_rate_unit VARCHAR(50),
    defect_risk_percent DECIMAL(5,2) DEFAULT 0,
    notes TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create index for processes
CREATE INDEX idx_processes_code ON processes(proc_code);
CREATE INDEX idx_processes_name ON processes(proc_name);
CREATE INDEX idx_processes_discipline ON processes(discipline);
CREATE INDEX idx_processes_parent ON processes(parent_id);

-- Recipes table
CREATE TABLE recipes (
    id SERIAL PRIMARY KEY,
    product_code VARCHAR(50) NOT NULL,
    product_name VARCHAR(255) NOT NULL,
    recipe_section VARCHAR(20) NOT NULL CHECK (recipe_section IN ('Material', 'Process')),
    sequence INTEGER NOT NULL,
    parent_sequence INTEGER,
    process_material_code VARCHAR(50) NOT NULL,
    process_name VARCHAR(255) NOT NULL,
    work_instruction TEXT,
    discipline VARCHAR(100),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (product_code) REFERENCES products(product_code) ON DELETE CASCADE
);

-- Create index for recipes
CREATE INDEX idx_recipes_product_code ON recipes(product_code);
CREATE INDEX idx_recipes_sequence ON recipes(sequence);
CREATE INDEX idx_recipes_section ON recipes(recipe_section);

-- Chat sessions table
CREATE TABLE chat_sessions (
    id SERIAL PRIMARY KEY,
    session_id UUID DEFAULT uuid_generate_v4() UNIQUE NOT NULL,
    user_message TEXT NOT NULL,
    ai_response TEXT,
    ai_provider VARCHAR(20) DEFAULT 'openai',
    recipe_generated BOOLEAN DEFAULT FALSE,
    product_code VARCHAR(50),
    processing_time_ms INTEGER,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create index for chat sessions
CREATE INDEX idx_chat_sessions_id ON chat_sessions(session_id);
CREATE INDEX idx_chat_sessions_created ON chat_sessions(created_at);

-- AI usage tracking table
CREATE TABLE ai_usage_log (
    id SERIAL PRIMARY KEY,
    session_id UUID,
    ai_provider VARCHAR(20) NOT NULL,
    model_used VARCHAR(50),
    input_tokens INTEGER,
    output_tokens INTEGER,
    total_tokens INTEGER,
    cost_estimate DECIMAL(10,4),
    processing_time_ms INTEGER,
    success BOOLEAN DEFAULT TRUE,
    error_message TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (session_id) REFERENCES chat_sessions(session_id) ON DELETE CASCADE
);

-- Create index for AI usage tracking
CREATE INDEX idx_ai_usage_provider ON ai_usage_log(ai_provider);
CREATE INDEX idx_ai_usage_created ON ai_usage_log(created_at);

-- User feedback table (for future improvements)
CREATE TABLE user_feedback (
    id SERIAL PRIMARY KEY,
    session_id UUID,
    recipe_id INTEGER,
    rating INTEGER CHECK (rating >= 1 AND rating <= 5),
    feedback_text TEXT,
    improvement_suggestions TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (session_id) REFERENCES chat_sessions(session_id) ON DELETE CASCADE,
    FOREIGN KEY (recipe_id) REFERENCES recipes(id) ON DELETE CASCADE
);

-- System configuration table
CREATE TABLE system_config (
    id SERIAL PRIMARY KEY,
    config_key VARCHAR(100) UNIQUE NOT NULL,
    config_value TEXT,
    description TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Insert default configuration
INSERT INTO system_config (config_key, config_value, description) VALUES
('default_ai_provider', 'openai', 'Default AI provider for recipe generation'),
('openai_model', 'gpt-4', 'Default OpenAI model to use'),
('claude_model', 'claude-3-sonnet-20240229', 'Default Claude model to use'),
('max_recipe_items', '50', 'Maximum number of items in a recipe'),
('admin_process_code', 'ADM-STD-ADMIN', 'Default admin process code'),
('pack_dispatch_keywords', 'pack,dispatch,shipping', 'Keywords for packing/dispatch processes');

-- Views for easier querying

-- Recipe summary view
CREATE VIEW recipe_summary AS
SELECT 
    r.product_code,
    r.product_name,
    COUNT(*) as total_items,
    COUNT(CASE WHEN r.recipe_section = 'Material' THEN 1 END) as material_count,
    COUNT(CASE WHEN r.recipe_section = 'Process' THEN 1 END) as process_count,
    MAX(r.created_at) as last_generated
FROM recipes r
GROUP BY r.product_code, r.product_name;

-- Popular products view
CREATE VIEW popular_products AS
SELECT 
    p.product_code,
    p.product_name,
    p.category,
    COUNT(cs.id) as request_count,
    COUNT(CASE WHEN cs.recipe_generated = TRUE THEN 1 END) as recipe_count
FROM products p
LEFT JOIN chat_sessions cs ON cs.product_code = p.product_code
GROUP BY p.product_code, p.product_name, p.category
ORDER BY request_count DESC;

-- AI provider performance view
CREATE VIEW ai_performance AS
SELECT 
    ai_provider,
    COUNT(*) as total_requests,
    COUNT(CASE WHEN success = TRUE THEN 1 END) as successful_requests,
    ROUND(COUNT(CASE WHEN success = TRUE THEN 1 END) * 100.0 / COUNT(*), 2) as success_rate,
    AVG(processing_time_ms) as avg_processing_time,
    SUM(total_tokens) as total_tokens_used,
    SUM(cost_estimate) as total_estimated_cost
FROM ai_usage_log
GROUP BY ai_provider;

-- Functions and Triggers

-- Function to update timestamp
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$ language 'plpgsql';

-- Create triggers for updated_at
CREATE TRIGGER update_products_updated_at BEFORE UPDATE ON products
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_materials_updated_at BEFORE UPDATE ON materials
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_processes_updated_at BEFORE UPDATE ON processes
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_recipes_updated_at BEFORE UPDATE ON recipes
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_chat_sessions_updated_at BEFORE UPDATE ON chat_sessions
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_system_config_updated_at BEFORE UPDATE ON system_config
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Function to search products by similarity
CREATE OR REPLACE FUNCTION search_products_by_similarity(search_term TEXT)
RETURNS TABLE(
    product_code VARCHAR(50),
    product_name VARCHAR(255),
    category VARCHAR(100),
    similarity_score FLOAT
) AS $
BEGIN
    RETURN QUERY
    SELECT 
        p.product_code,
        p.product_name,
        p.category,
        GREATEST(
            similarity(LOWER(p.product_name), LOWER(search_term)),
            similarity(LOWER(p.category), LOWER(search_term)),
            similarity(LOWER(COALESCE(p.short_description, '')), LOWER(search_term))
        ) as similarity_score
    FROM products p
    WHERE 
        LOWER(p.product_name) LIKE '%' || LOWER(search_term) || '%'
        OR LOWER(p.category) LIKE '%' || LOWER(search_term) || '%'
        OR LOWER(COALESCE(p.short_description, '')) LIKE '%' || LOWER(search_term) || '%'
    ORDER BY similarity_score DESC
    LIMIT 10;
END;
$ LANGUAGE plpgsql;

-- Function to get process hierarchy
CREATE OR REPLACE FUNCTION get_process_hierarchy(parent_proc_code VARCHAR(50))
RETURNS TABLE(
    level INTEGER,
    proc_code VARCHAR(50),
    proc_name VARCHAR(255),
    parent_code VARCHAR(50)
) AS $
WITH RECURSIVE process_tree AS (
    -- Base case: find the parent process
    SELECT 
        1 as level,
        p.proc_code,
        p.proc_name,
        CAST(NULL as VARCHAR(50)) as parent_code
    FROM processes p 
    WHERE p.proc_code = parent_proc_code
    
    UNION ALL
    
    -- Recursive case: find child processes
    SELECT 
        pt.level + 1,
        p.proc_code,
        p.proc_name,
        pt.proc_code as parent_code
    FROM processes p
    INNER JOIN process_tree pt ON p.parent_id = (
        SELECT sort_id FROM processes WHERE proc_code = pt.proc_code
    )
    WHERE pt.level < 5  -- Prevent infinite recursion
)
SELECT * FROM process_tree;
$ LANGUAGE sql;

-- Data validation functions
CREATE OR REPLACE FUNCTION validate_recipe_sequence()
RETURNS TRIGGER AS $
BEGIN
    -- Ensure sequence numbers are unique within a product recipe
    IF EXISTS (
        SELECT 1 FROM recipes 
        WHERE product_code = NEW.product_code 
        AND sequence = NEW.sequence 
        AND id != COALESCE(NEW.id, 0)
    ) THEN
        RAISE EXCEPTION 'Sequence number % already exists for product %', NEW.sequence, NEW.product_code;
    END IF;
    
    -- Ensure parent_sequence exists if specified
    IF NEW.parent_sequence IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM recipes 
            WHERE product_code = NEW.product_code 
            AND sequence = NEW.parent_sequence
        ) THEN
            RAISE EXCEPTION 'Parent sequence % does not exist for product %', NEW.parent_sequence, NEW.product_code;
        END IF;
    END IF;
    
    RETURN NEW;
END;
$ LANGUAGE plpgsql;

-- Create trigger for recipe validation
CREATE TRIGGER validate_recipe_sequence_trigger 
    BEFORE INSERT OR UPDATE ON recipes
    FOR EACH ROW EXECUTE FUNCTION validate_recipe_sequence();

-- Sample data insertion function
CREATE OR REPLACE FUNCTION insert_sample_data()
RETURNS VOID AS $
BEGIN
    -- Insert sample products
    INSERT INTO products (product_code, product_name, category, core_capability, short_description) VALUES
    ('PRD-0001', 'ACM Panel Signs', 'Permanent Building Signage', TRUE, 'Robust aluminium composite sign printed in full colour, laminated for UV protection'),
    ('PRD-0002', 'Vinyl Banners', 'Temporary Signage', TRUE, 'Durable vinyl banner with full colour printing and eyelet options'),
    ('PRD-0003', 'Corflute Signs', 'Temporary Signage', TRUE, 'Lightweight corrugated plastic signs ideal for short-term advertising'),
    ('PRD-0004', 'Illuminated Lightbox', 'Illuminated Signage', FALSE, 'LED backlit signage with replaceable faces');

    -- Insert sample materials
    INSERT INTO materials (partcode, friendly_description, base, sub, thk) VALUES
    ('ACM-STD-WHI-000-3', 'ACM Standard Grade White 3mm', 'acm', 'std', 3.0),
    ('SAV-MON-WHI-PER-0', 'SAV Monomeric White Permanent', 'sav', 'mon', 0.0),
    ('LAM-MON-CLR-UVS-0', 'Laminate Monomeric Clear UV-Stabilised', 'lam', 'mon', 0.0),
    ('CFL-STD-WHI-000-5', 'Corrugated Flute Board White 5mm', 'cfl', 'std', 5.0),
    ('EYE-MET-SIL-012-0', 'Metal Eyelets Silver 12mm', 'eye', 'met', 0.0);

    -- Insert sample processes
    INSERT INTO processes (sort_id, parent_id, proc_code, proc_name, discipline, setup_time_min, run_rate_unit) VALUES
    (5, 0, 'ADM-STD-ADMIN', 'Administration & Planning', 'Administration', 15, 'jobs/hr'),
    (30, 0, 'DES-AS', 'Artwork Setup', 'Design & Pre-Press', 15, 'files/hr'),
    (50, 0, 'PRT-RTR', 'Roll to Roll Digital Print', 'Printing', 30, 'sqm/hr'),
    (70, 0, 'FIN-CLR', 'Cold Laminate Roll', 'Surface Finishing', 10, 'sqm/hr'),
    (90, 0, 'ASM-MTS', 'Mount SAV to Substrate', 'Mounting & Assembly', 20, 'sqm/hr'),
    (110, 0, 'CUT-CNC', 'CNC Route Rigid', 'Cutting & Shaping', 25, 'pcs/hr'),
    (150, 0, 'FIN-EYE', 'Eyelet Installation', 'Finishing', 5, 'eyelets/min'),
    (200, 0, 'PCK-STD', 'Standard Packing', 'Packing & Dispatch', 10, 'items/hr');

    RAISE NOTICE 'Sample data inserted successfully';
END;
$ LANGUAGE plpgsql;

-- Performance monitoring function
CREATE OR REPLACE FUNCTION get_system_performance()
RETURNS TABLE(
    metric_name VARCHAR(50),
    metric_value NUMERIC,
    metric_unit VARCHAR(20)
) AS $
BEGIN
    RETURN QUERY
    SELECT 'Total Products'::VARCHAR(50), COUNT(*)::NUMERIC, 'count'::VARCHAR(20) FROM products
    UNION ALL
    SELECT 'Total Materials'::VARCHAR(50), COUNT(*)::NUMERIC, 'count'::VARCHAR(20) FROM materials
    UNION ALL
    SELECT 'Total Processes'::VARCHAR(50), COUNT(*)::NUMERIC, 'count'::VARCHAR(20) FROM processes
    UNION ALL
    SELECT 'Total Recipes'::VARCHAR(50), COUNT(*)::NUMERIC, 'count'::VARCHAR(20) FROM recipes
    UNION ALL
    SELECT 'Chat Sessions Today'::VARCHAR(50), COUNT(*)::NUMERIC, 'count'::VARCHAR(20) 
    FROM chat_sessions WHERE created_at >= CURRENT_DATE
    UNION ALL
    SELECT 'Avg Processing Time'::VARCHAR(50), AVG(processing_time_ms)::NUMERIC, 'ms'::VARCHAR(20) 
    FROM ai_usage_log WHERE created_at >= CURRENT_DATE - INTERVAL '7 days'
    UNION ALL
    SELECT 'Success Rate'::VARCHAR(50), 
           (COUNT(CASE WHEN success THEN 1 END) * 100.0 / COUNT(*))::NUMERIC, 
           'percent'::VARCHAR(20) 
    FROM ai_usage_log WHERE created_at >= CURRENT_DATE - INTERVAL '7 days';
END;
$ LANGUAGE plpgsql;

-- Cleanup function for old data
CREATE OR REPLACE FUNCTION cleanup_old_data(days_to_keep INTEGER DEFAULT 90)
RETURNS INTEGER AS $
DECLARE
    deleted_count INTEGER := 0;
BEGIN
    -- Delete old chat sessions and related data
    WITH deleted AS (
        DELETE FROM chat_sessions 
        WHERE created_at < CURRENT_DATE - INTERVAL '1 day' * days_to_keep
        RETURNING id
    )
    SELECT COUNT(*) INTO deleted_count FROM deleted;
    
    -- Delete orphaned AI usage logs
    DELETE FROM ai_usage_log 
    WHERE session_id NOT IN (SELECT session_id FROM chat_sessions);
    
    -- Delete orphaned recipes (if product doesn't exist)
    DELETE FROM recipes 
    WHERE product_code NOT IN (SELECT product_code FROM products);
    
    RAISE NOTICE 'Cleaned up % old records', deleted_count;
    RETURN deleted_count;
END;
$ LANGUAGE plpgsql;

-- Create indexes for better performance
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_recipes_product_sequence 
    ON recipes(product_code, sequence);

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_chat_sessions_date 
    ON chat_sessions(DATE(created_at));

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_ai_usage_date_provider 
    ON ai_usage_log(DATE(created_at), ai_provider);

-- Full-text search indexes (if using PostgreSQL with full-text search)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_products_fts 
    ON products USING gin(to_tsvector('english', product_name || ' ' || COALESCE(short_description, '')));

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_materials_fts 
    ON materials USING gin(to_tsvector('english', friendly_description));

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_processes_fts 
    ON processes USING gin(to_tsvector('english', proc_name || ' ' || COALESCE(notes, '')));

-- Insert sample data
SELECT insert_sample_data();

-- Grant permissions (adjust as needed for your setup)
-- GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO your_app_user;
-- GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO your_app_user;
-- GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO your_app_user;

COMMIT;
