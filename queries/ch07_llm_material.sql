-- ch07_llm_material.sql -- Inspect aggregate material before sharing with an external LLM
-- codes/sql-code-eng/queries/ch07_llm_material.sql@v1.2.2
-- Learning data only. Does not transmit query results to any service.
BEGIN READ ONLY;
SET LOCAL search_path TO sakura, public;
SET LOCAL TIME ZONE 'America/New_York';
SELECT status, count(*) AS orders
FROM orders
GROUP BY status
HAVING count(*) >= 10
ORDER BY status;
ROLLBACK;
