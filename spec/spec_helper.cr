# SPDX-License-Identifier: AGPL-3.0-or-later

ENV["MARTEN_ENV"] = "test"

require "spec"

require "../src/partiduo_ui"
# Extension factice montée sous /ext/UITEST/ (contrôle d'accès des extensions).
require "./fixtures/uitest/app"
require "marten/spec"
require "marten_auth/spec"

require "./support/**"
