--------------------------------------------------------------------------------
-- Snowflake PAT Expiry Alert - MODULAR version (parameters = "variables")
-- Account : **********
-- Run as  : DEVOPS_ROLE
-- WH      : IT_PAT_ALERT_WH
-- Context : DATABASE SYSTEM, SCHEMA PUBLIC
--
-- "Variables" (set at CALL time, no code edit needed):
--   DAYS_THRESHOLD    -> how many days ahead to warn (30, 7, ...)
--   USER_NAME_PATTERN -> which users to check ('%SERVICE%', '%' for all, or a name)
--
-- "Modules" (each is a single-purpose Python function inside the SP):
--   M1 get_filtered_users  -> users matching the keyword + their emails
--   M2 get_expiring_pats   -> ACTIVE PATs for those users within the window
--   M3 format_pat_table    -> readable text table (user | pat | expires | days)
--   M4 send_email          -> one SYSTEM$SEND_EMAIL call
--   ROOT sys_it_pat_...    -> orchestrates M1..M4, emails each user their own PATs
--------------------------------------------------------------------------------

-- =============================================================================
-- PREREQ GRANTS (run ONCE as ACCOUNTADMIN)
--   SECURITY_VIEWER -> ACCOUNT_USAGE.CREDENTIALS
--   OBJECT_VIEWER   -> ACCOUNT_USAGE.USERS (user names + emails)
--   Broad alternative: GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO ROLE DEVOPS_ROLE;
-- =============================================================================
-- USE ROLE ACCOUNTADMIN;
-- GRANT DATABASE ROLE SNOWFLAKE.SECURITY_VIEWER TO ROLE DEVOPS_ROLE;
-- GRANT DATABASE ROLE SNOWFLAKE.OBJECT_VIEWER   TO ROLE DEVOPS_ROLE;
-- GRANT USAGE ON DATABASE SYSTEM TO ROLE DEVOPS_ROLE;
-- GRANT USAGE ON SCHEMA SYSTEM.PUBLIC TO ROLE DEVOPS_ROLE;
-- GRANT CREATE PROCEDURE ON SCHEMA SYSTEM.PUBLIC TO ROLE DEVOPS_ROLE;
-- GRANT CREATE TASK ON SCHEMA SYSTEM.PUBLIC TO ROLE DEVOPS_ROLE;
-- GRANT EXECUTE TASK ON ACCOUNT TO ROLE DEVOPS_ROLE;
-- GRANT CREATE INTEGRATION ON ACCOUNT TO ROLE DEVOPS_ROLE;  -- only if DEVOPS_ROLE creates the integration

-- =============================================================================
-- MAIN SCRIPT (run as DEVOPS_ROLE)
-- =============================================================================
USE ROLE DEVOPS_ROLE;
USE WAREHOUSE IT_PAT_ALERT_WH;
USE DATABASE SYSTEM;
USE SCHEMA PUBLIC;

-- 1) Notification integration (idempotent; needs CREATE INTEGRATION - run as
--    ACCOUNTADMIN if DEVOPS_ROLE lacks it)
CREATE OR REPLACE NOTIFICATION INTEGRATION PAT_EMAIL_INT
  TYPE = EMAIL
  ENABLED = TRUE;
GRANT USAGE ON INTEGRATION PAT_EMAIL_INT TO ROLE DEVOPS_ROLE;

-- 2) Modular stored procedure
CREATE OR REPLACE PROCEDURE SYS_IT_PAT_EXPIRY_ALERTS_PROCEDURE(
    DAYS_THRESHOLD    FLOAT,
    USER_NAME_PATTERN STRING
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'sys_it_pat_expiry_alerts_procedure'
AS
$$
from snowflake.snowpark import Session

EMAIL_INTEGRATION = 'PAT_EMAIL_INT'

# Sign-off / sender team shown at the bottom of every alert email.
# (Note: with TYPE=EMAIL the actual From address is fixed to
#  no-reply@snowflake.net by Snowflake; this is just the closing line.)
SIGN_OFF = 'TTID-DATA-SERVICE-TEAM'

def esc(s):
    return str(s).replace("'", "''")

# ---- MODULE 1: users matching the keyword + their emails --------------------
def get_filtered_users(session, pattern):
    # NOTE: do NOT filter on email here. We want to CHECK every matching
    # service user's PATs even if they have no email yet - otherwise the
    # procedure silently reports "No PATs" just because the email is missing.
    # The email requirement is enforced only at send time (see ROOT).
    q = """
        SELECT name, email
        FROM SNOWFLAKE.ACCOUNT_USAGE.USERS
        WHERE deleted_on IS NULL
          AND UPPER(name) LIKE UPPER(?)
    """
    return session.sql(q, [pattern]).collect()

# ---- MODULE 2: ACTIVE PATs for those users within the day window ------------
def get_expiring_pats(session, user_names, days_threshold):
    if not user_names:
        return []
    in_list = ", ".join("'" + u.replace("'", "''") + "'" for u in user_names)
    # Pull ALL active PATs for the filtered users, then apply the day window
    # in Python. This avoids any DATEADD()+parameter-binding ambiguity (which
    # caused "No PATs" to be returned even when a PAT was in the window) and is
    # trivial to reason about / debug.
    q = f"""
        SELECT c.user_name,
               c.name                                                 AS pat_name,
               TO_CHAR(CONVERT_TIMEZONE('UTC', c.expiration_date),
                       'YYYY-MM-DD HH24:MI')                          AS expires_utc,
               DATEDIFF(day, CURRENT_DATE(), c.expiration_date::DATE) AS days_left
        FROM SNOWFLAKE.ACCOUNT_USAGE.CREDENTIALS c
        WHERE c.type = 'PAT'
          AND c.status = 'ACTIVE'
          AND c.user_name IN ({in_list})
    """
    rows = session.sql(q).collect()
    out = []
    for r in rows:
        d = r["DAYS_LEFT"]
        if d is None:
            continue
        d = float(d)
        # 0 = expires today; >threshold = too far out. Keep only the warning window.
        if 0 <= d <= days_threshold:
            out.append(r)
    out.sort(key=lambda r: float(r["DAYS_LEFT"]) if r["DAYS_LEFT"] is not None else 0)
    return out

# ---- MODULE 3: HTML table (aligns in ANY email client, font-independent) ---
def esc_html(s):
    # Prevent a stray <, >, & or " in a PAT/user name from breaking the markup.
    return (str(s).replace("&", "&amp;")
                   .replace("<", "&lt;")
                   .replace(">", "&gt;")
                   .replace('"', "&quot;"))

def format_pat_table(rows):
    thead = (
        "<table border='1' cellspacing='0' cellpadding='6' "
        "style='border-collapse:collapse;font-family:Arial,Helvetica,sans-serif;"
        "font-size:13px;'>"
        "<thead><tr style='background-color:#f2f2f2;'>"
        "<th style='text-align:left;padding:6px 10px;'>User</th>"
        "<th style='text-align:left;padding:6px 10px;'>PAT Name</th>"
        "<th style='text-align:left;padding:6px 10px;'>Expires (UTC)</th>"
        "<th style='text-align:left;padding:6px 10px;'>Days Left</th>"
        "</tr></thead><tbody>"
    )
    tbody = ""
    for r in rows:
        tbody += (
            "<tr>"
            f"<td style='padding:6px 10px;'>{esc_html(r['USER_NAME'])}</td>"
            f"<td style='padding:6px 10px;'>{esc_html(r['PAT_NAME'])}</td>"
            f"<td style='padding:6px 10px;'>{esc_html(r['EXPIRES_UTC'])}</td>"
            f"<td style='padding:6px 10px;'>{esc_html(r['DAYS_LEFT'])}</td>"
            "</tr>"
        )
    return thead + tbody + "</tbody></table>"

# ---- MODULE 4: send one email (HTML) ---------------------------------------
def send_email(session, recipient, subject, body):
    # 5th arg 'text/html' => the table renders aligned in every mail client.
    session.sql(
        f"CALL SYSTEM$SEND_EMAIL('{esc(EMAIL_INTEGRATION)}', '{esc(recipient)}', "
        f"'{esc(subject)}', '{esc(body)}', 'text/html')"
    ).collect()

# ---- ROOT MODULE: orchestrates M1..M4 ---------------------------------------
def sys_it_pat_expiry_alerts_procedure(session, days_threshold, user_name_pattern):
    users = get_filtered_users(session, user_name_pattern)
    if not users:
        return f"No users match pattern '{user_name_pattern}'. Nothing to check."

    # Map each matched user -> email. Normalize so we can group by address.
    email_by_user = {}
    for u in users:
        email_by_user[u['NAME']] = (u['EMAIL'] or '').strip()
    user_names = list(email_by_user.keys())

    pats = get_expiring_pats(session, user_names, days_threshold)
    if not pats:
        return (f"No PATs expiring within {int(days_threshold)} days for users "
                f"matching '{user_name_pattern}'.")

    # GROUP BY RECIPIENT EMAIL (not by user) so that:
    #  - one user with several PATs  -> a single email listing all of them
    #  - two users sharing one email -> a single email listing both users' PATs
    by_email = {}
    no_email_users = []
    for p in pats:
        user = p['USER_NAME']
        recipient = email_by_user.get(user)
        if not recipient:
            # PAT is expiring but this user has no EMAIL set -> cannot notify.
            no_email_users.append(user)
            continue
        by_email.setdefault(recipient, []).append(p)

    sent = 0
    failed = []
    for recipient, rows in by_email.items():
        users_in = sorted(set(str(r['USER_NAME']) for r in rows))
        subject = (f"[Snowflake] PAT(s) expiring within {int(days_threshold)} days "
                   f"for: " + ", ".join(users_in))
        body = (
            "<p>Hello,</p>"
            f"<p>The following Snowflake PAT(s) will expire soon "
            f"(warning window: {int(days_threshold)} days). "
            f"PATs stop working after expiry - please create a replacement.</p>"
            f"{format_pat_table(rows)}"
            f"<p>Best regards,<br>{SIGN_OFF}</p>"
        )
        try:
            send_email(session, recipient, subject, body)
            sent += 1
        except Exception as e:
            failed.append(recipient)
            print(f"Failed to send to {recipient}: {e}")

    result = (f"Checked {len(user_names)} user(s); "
              f"{len(pats)} PAT(s) flagged; {sent} email(s) sent.")
    if no_email_users:
        result += (" Users WITHOUT an email (NOT notified - set+verify their "
                   "EMAIL attr): " + ", ".join(sorted(set(no_email_users))))
    if failed:
        result += " Failed sends (email not verified?): " + ", ".join(failed)
    return result
$$;

-- 3) Daily task (09:00 Asia/Shanghai) - note it now passes the "variables"
CREATE OR REPLACE TASK SYS_IT_PAT_EXPIRY_ALERTS_TASK
  WAREHOUSE = IT_PAT_ALERT_WH
  SCHEDULE = 'USING CRON 0 9 * * * Asia/Shanghai'
AS
  CALL SYS_IT_PAT_EXPIRY_ALERTS_PROCEDURE(30, '%SERVICE%');

ALTER TASK SYS_IT_PAT_EXPIRY_ALERTS_TASK RESUME;

-- =============================================================================
-- CALL EXAMPLES - change the "variables", no code edit needed
-- =============================================================================
-- Service users, 30 days (the default the task uses):
--   CALL SYS_IT_PAT_EXPIRY_ALERTS_PROCEDURE(30, '%SERVICE%');
-- Same users, 7 days:
--   CALL SYS_IT_PAT_EXPIRY_ALERTS_PROCEDURE(7, '%SERVICE%');
-- ALL users, 30 days:
--   CALL SYS_IT_PAT_EXPIRY_ALERTS_PROCEDURE(30, '%');
-- One specific user:
--   CALL SYS_IT_PAT_EXPIRY_ALERTS_PROCEDURE(30, 'RND_TTR_SF_SERVICE_USER');

-- Verify it is live:
-- SHOW TASKS LIKE 'SYS_IT_PAT_EXPIRY_ALERTS_TASK';
-- SELECT * FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY())
-- WHERE NAME = 'SYS_IT_PAT_EXPIRY_ALERTS_TASK' ORDER BY SCHEDULED_TIME DESC;
