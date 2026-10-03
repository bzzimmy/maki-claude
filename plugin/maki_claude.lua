-- Claude subscription (Pro or Max) for maki, over the Claude Code OAuth flow.
-- The subscription token is accepted only when the system prompt opens with
-- the Claude Code identity line as its own block, which is the system prefix.

local SLUG = "claude"
local DISPLAY_NAME = "Claude subscription"
local IDENTITY = "You are Claude Code, Anthropic's official CLI for Claude."
local CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
local AUTHORIZE_URL = "https://claude.ai/oauth/authorize"
-- The provider origin: maki.net sends a browser user agent anywhere else, which
-- the token endpoint answers with a 429.
local TOKEN_URL = "https://api.anthropic.com/v1/oauth/token"
local REDIRECT_URI = "https://platform.claude.com/oauth/code/callback"
local SCOPES =
  "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
local REFRESH_MARGIN_S = 300
local PKCE_WAIT_MS = 10000
-- Prints a random verifier, then its S256 challenge in standard base64.
local PKCE_SCRIPT =
  'v=$(openssl rand -hex 32) && echo "$v" && printf %s "$v" | openssl dgst -sha256 -binary | openssl base64 -A'
local NOT_LOGGED_IN = "not logged in to Claude: run `maki auth login claude`"
-- Claude Code sends this when the install is enrolled in a server-side
-- experiment. Override with CLAUDE_ATIS, or set it to "off" to omit the header.
local ATIS_DEFAULT = "d5ce23808f17634f"

local function urlencode(value)
  return (value:gsub("[^%w%-_%.~]", function(c)
    return ("%%%02X"):format(c:byte())
  end))
end

local function pkce()
  local job, err = maki.fn.jobstart({ "sh", "-c", PKCE_SCRIPT }, { scope = "plugin" })
  if not job then
    error("cannot run openssl: " .. tostring(err))
  end
  local result = maki.fn.jobwait(job, PKCE_WAIT_MS)
  local verifier, challenge = ((result and result.stdout) or ""):match("^(%x+)\n(%S+)")
  if not verifier then
    error("openssl did not produce a PKCE pair, is it installed?")
  end
  return verifier, (challenge:gsub("+", "-"):gsub("/", "_"):gsub("=", ""))
end

-- Posts to the token endpoint and stores what it grants. On an HTTP failure
-- returns nil and the response.
local function grant(slug, body, previous)
  local res, err = maki.net.request(TOKEN_URL, {
    method = "POST",
    headers = { ["content-type"] = "application/json", accept = "application/json" },
    body = maki.json.encode(body),
  })
  if not res then
    error(TOKEN_URL .. " unreachable: " .. tostring(err))
  end
  if res.status < 200 or res.status >= 300 then
    return nil, res
  end
  local data = maki.json.decode(res.body)
  local refresh = type(data) == "table" and (data.refresh_token or (previous and previous.refresh))
  if not refresh or type(data.access_token) ~= "string" or type(data.expires_in) ~= "number" then
    error("token response is missing access_token, refresh_token or expires_in")
  end
  local creds = { access = data.access_token, refresh = refresh, expires = os.time() + math.floor(data.expires_in) }
  local ok, set_err = maki.provider.auth.set(slug, creds)
  if not ok then
    error("cannot store the Claude tokens: " .. tostring(set_err))
  end
  return creds
end

-- Accepts the `code#state` the callback page shows, or the redirect URL.
local function parse_code(input)
  local code = input:match("code=([^&#%s]+)") or input:match("^%s*([^#%s]+)")
  local state = input:match("state=([^&#%s]+)") or input:match("#(%S+)")
  return code, state
end

local function auth(ctx, purpose)
  local creds = maki.provider.auth.get(ctx.slug)
  if not creds then
    error(NOT_LOGGED_IN)
  end
  if purpose == "refresh" or (purpose == "resolve" and creds.expires <= os.time() + REFRESH_MARGIN_S) then
    local res
    creds, res =
      grant(ctx.slug, { grant_type = "refresh_token", client_id = CLIENT_ID, refresh_token = creds.refresh }, creds)
    if not creds then
      return nil, maki.provider.http_error(res)
    end
  end
  local headers = { authorization = "Bearer " .. creds.access }
  local atis = maki.uv.os_getenv("CLAUDE_ATIS") or ATIS_DEFAULT
  if atis ~= "" and atis ~= "off" then
    headers["x-cc-atis"] = atis
  end
  return { headers = headers }
end

local function login(ctx)
  local verifier, challenge = pkce()
  -- The authorize page accepts the verifier as state, which is what pi sends.
  local query = {
    "code=true",
    "client_id=" .. CLIENT_ID,
    "response_type=code",
    "redirect_uri=" .. urlencode(REDIRECT_URI),
    "scope=" .. urlencode(SCOPES),
    "code_challenge=" .. challenge,
    "code_challenge_method=S256",
    "state=" .. verifier,
  }
  local url = AUTHORIZE_URL .. "?" .. table.concat(query, "&")
  ctx.print("Log in to Claude in your browser:\n\n  " .. url .. "\n")
  ctx.open_url(url)
  local code, state = parse_code(ctx.prompt({ label = "Paste the code shown after you approve: " }) or "")
  if not code then
    error("no code entered, nothing was stored")
  end
  if state and state ~= verifier then
    error("OAuth state mismatch, start the login again")
  end
  local creds, res = grant(ctx.slug, {
    grant_type = "authorization_code",
    client_id = CLIENT_ID,
    code = code,
    state = verifier,
    redirect_uri = REDIRECT_URI,
    code_verifier = verifier,
  })
  if not creds then
    error(("%s answered %d: %s"):format(TOKEN_URL, res.status, res.body))
  end
  ctx.print("Logged in. Pick a model with /model, for example claude/claude-opus-5.")
end

local function logout(ctx)
  maki.provider.auth.clear(ctx.slug)
  ctx.print("Claude tokens removed")
end

maki.provider.register({
  slug = SLUG,
  display_name = DISPLAY_NAME,
  base = "anthropic",
  system_prefix = IDENTITY,
  auth = auth,
  login = login,
  logout = logout,
})
