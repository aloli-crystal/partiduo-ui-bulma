# SPDX-License-Identifier: AGPL-3.0-or-later

ENV["MARTEN_ENV"] = "test"

require "spec"

require "../src/partiduo_ui"
require "marten/spec"
require "marten_auth/spec"

require "./support/**"
