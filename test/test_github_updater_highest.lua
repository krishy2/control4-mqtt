-- Tests that the updater picks the release with the highest version, whatever
-- order GitHub lists them in.
--
-- GitHub's release list is not in version order: on this repository it put
-- v20261030 before v2026102500 (tag names compared as text), and an updater
-- that took the first entry never saw the newer release.
--
-- Run from the repo root:
--   make test
-- or:
--   ./test/run_test.sh test_github_updater_highest.lua

local T = require("testlib")
require("c4_shim")
require("drivers-common-public.global.lib")
JSON = require("JSON")
local deferred = require("deferred")
local http = require("lib.http")
local updater = require("lib.github-updater")

local listed = {}
http.get = function(_, url)
  if url:find("/releases$") then
    return deferred.new():resolve({ body = listed })
  end
  return deferred.new():resolve({ body = "payload" })
end

local function release(tag, opts)
  opts = opts or {}
  return { tag_name = tag, name = tag, draft = opts.draft or false, prerelease = opts.prerelease or false, assets = {} }
end

local function latest(includePrereleases)
  local picked, failure
  updater:getLatestRelease("krishy2/control4-mqtt", includePrereleases):next(function(r)
    picked = r.tag_name
  end, function(e)
    failure = e
  end)
  return picked, failure
end

T.section("Highest version wins")
listed = { release("v20261030"), release("v2026102500") }
T.eq("the order GitHub actually used", latest(), "v2026102500")
listed = { release("v2026102500"), release("v20261030") }
T.eq("the other order", latest(), "v2026102500")
listed = { release("v2026102501"), release("v20261030"), release("v2026102500"), release("v20260415") }
T.eq("several releases in mixed order", latest(), "v2026102501")

T.section("Drafts, pre-releases and bad tags")
listed = { release("v2026102600", { draft = true }), release("v2026102500") }
T.eq("a draft is never picked", latest(), "v2026102500")
listed = { release("v2026102600-rc1", { prerelease = true }), release("v2026102500") }
T.eq("Production channel skips pre-releases", latest(false), "v2026102500")
T.eq("Prerelease channel takes the newer pre-release", latest(true), "v2026102600-rc1")
listed = { release("latest-build"), release("v2026102500") }
local picked
T.capture(function()
  picked = latest()
end)
T.eq("an invalid tag is skipped", picked, "v2026102500")
listed = { release("v2026102600", { draft = true }) }
local none, failure = latest()
T.eq("no valid release: nothing picked", none, nil)
T.contains("and an error", failure, "does not have any valid releases")

T.finish()
