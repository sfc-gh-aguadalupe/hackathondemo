-- =====================================================================
-- Lumora Value Loop demo — 50_deploy_streamlit.sql
--
-- Deploys app/lumora_app.py as Streamlit in Snowflake.
--
-- PUT is a client-side command, so this script must run from a client that
-- can read the local files (Snowflake CLI, SnowSQL, or a driver session) —
-- it will not work from a worksheet.
--
--   snow sql -c <your-connection> -f sql/50_deploy_streamlit.sql
--
-- Paths assume the repository root is the working directory.
-- =====================================================================

USE SCHEMA LUMORA_DEMO.APP;

CREATE STAGE IF NOT EXISTS LUMORA_DEMO.APP.APP_STAGE
  DIRECTORY = (ENABLE = TRUE)
  COMMENT = 'Streamlit app source for the Lumora cockpit';

PUT file://app/lumora_app.py   @LUMORA_DEMO.APP.APP_STAGE/lumora_cockpit/ OVERWRITE = TRUE AUTO_COMPRESS = FALSE;
PUT file://app/environment.yml @LUMORA_DEMO.APP.APP_STAGE/lumora_cockpit/ OVERWRITE = TRUE AUTO_COMPRESS = FALSE;

CREATE OR REPLACE STREAMLIT LUMORA_DEMO.APP.LUMORA_COCKPIT
  ROOT_LOCATION = '@LUMORA_DEMO.APP.APP_STAGE/lumora_cockpit'
  MAIN_FILE = 'lumora_app.py'
  QUERY_WAREHOUSE = LUMORA_WH
  COMMENT = 'Lumora Value Loop CFO decision cockpit. All financial values are illustrative synthetic figures.';

-- Pin the staged files as the served version.
ALTER STREAMLIT LUMORA_DEMO.APP.LUMORA_COCKPIT ADD LIVE VERSION FROM LAST;

SHOW STREAMLITS IN SCHEMA LUMORA_DEMO.APP;
