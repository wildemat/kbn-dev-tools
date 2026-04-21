# Browser Interaction & Authentication

## Handling login screens

When you navigate to a Kibana instance and see a login/auth screen
instead of the expected page, handle it automatically:

### Serverless (port 5601) — Role selector

The dev serverless instance uses mock authentication. Instead of a
username/password form, you'll see a **role selection page** with
profile cards for different roles (e.g. `admin`, `editor`, `viewer`,
`t1_analyst`, `t2_analyst`, etc.).
- Look for a card/button labeled **"admin"** (or containing "admin"
  in the role name) and click it.
- Default to `admin` unless the user specifically requests a different role.
- After selecting a role, you'll be redirected to the Kibana app. If
  you land on a space selector, pick **Default** space.
- There is no password. Just select the role.

### Stateful (port 5611) — Login form

The stateful instance uses a standard login form.
- Find the **username** input field and type: `elastic`
- Find the **password** input field and type: `changeme`
- Click the **"Log in"** button.
- If you see an "Enter code" or enrollment screen instead, the ES
  cluster may not be configured correctly — report this to the user.

### Detecting auth screens

- If the URL contains `/login` or the page shows "Log in to Elastic"
  or a role selector grid, you're on an auth page.
- If you see a 401 or "Unauthorized" response, the session expired —
  repeat the login flow.
- After successful auth, navigate to the originally requested URL.

## Curl with auth

**Stateful** uses basic auth:
```bash
curl -s -u elastic:changeme http://localhost:5611/api/status
curl -s -u elastic:changeme http://localhost:5611/app/elasticsearch/start
curl -s -u elastic:changeme "http://localhost:5611/api/console/proxy?path=_cat/indices&method=GET"
```

**Serverless** in dev mode uses cookie-based auth:
```bash
curl -s -c /tmp/kbn-sls-cookie -L http://localhost:5601/app/home
curl -s -b /tmp/kbn-sls-cookie http://localhost:5601/api/status
```

**ES clusters directly:**
```bash
curl -s http://localhost:9200/_cat/indices?v                        # serverless ES
curl -s -u elastic:changeme http://localhost:9201/_cat/indices?v    # stateful ES
```

## Common Kibana app paths

- Getting started / onboarding: `/app/elasticsearch/start`
- Search / indices: `/app/enterprise_search/elasticsearch`
- Dev Tools console: `/app/dev_tools#/console`
- Discover: `/app/discover`
- Stack Management: `/app/management`
- Dashboards: `/app/dashboards`
