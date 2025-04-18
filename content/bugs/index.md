+++
title = "list of production bugs i added"
url = "/bugs"
date = "2025-04-18"
+++

{{< rca 
    title="race condition from non-atomic 'check-then-insert/update' pattern in application logic"
    date="2025-04-18"
    severity="low"
    time="<1h"
    problem="concurrent requests caused a database integrity violation."
    cause="the check and insert logic in the application code wasn't atomic, allowing concurrent requests to break the uniqueness integrity expected by the application code. solution: use atomic upsert in the application code instead."
    notes="correlation ids from production alerts pointed to failing requests, but those weren’t the ones that caused the integrity issue. searching logs for the successful concurrent requests that put the database into the inconsistent state cut the time to identify the issue."
>}}

