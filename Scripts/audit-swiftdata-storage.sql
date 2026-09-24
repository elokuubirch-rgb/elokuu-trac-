-- 只在已验证一致的本地数据库副本上用 sqlite3 -readonly 执行。
-- 没有 VACUUM、DELETE、UPDATE 或 schema 变更。
PRAGMA query_only = ON;
PRAGMA quick_check;
PRAGMA page_size;
PRAGMA page_count;
PRAGMA freelist_count;
SELECT type, name, tbl_name FROM sqlite_schema
WHERE type IN ('table', 'index') ORDER BY type, name;
SELECT name, COUNT(*) AS pages, SUM(pgsize) AS allocated_bytes,
       SUM(payload) AS payload_bytes, SUM(unused) AS unused_bytes
FROM dbstat GROUP BY name ORDER BY allocated_bytes DESC;
