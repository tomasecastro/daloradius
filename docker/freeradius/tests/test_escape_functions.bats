#!/usr/bin/env bats
# Tests for pure helper functions: escape_sed_replacement and sql_escape.
#
# These functions have no external dependencies, so they are the safest to
# test and the most valuable as regression guards.

load test_helpers

@test "escape_sed_replacement escapes slashes" {
	run escape_sed_replacement "a/b/c"
	[ "$status" -eq 0 ]
	[ "$output" = "a\/b\/c" ]
}

@test "escape_sed_replacement escapes ampersands" {
	run escape_sed_replacement "a&b"
	[ "$status" -eq 0 ]
	[ "$output" = "a\&b" ]
}

@test "escape_sed_replacement escapes pipes" {
	run escape_sed_replacement "a|b"
	[ "$status" -eq 0 ]
	[ "$output" = "a\|b" ]
}

@test "escape_sed_replacement escapes backslashes" {
	run escape_sed_replacement "a\b"
	[ "$status" -eq 0 ]
	[ "$output" = "a\\b" ]
}

@test "escape_sed_replacement leaves plain strings unchanged" {
	run escape_sed_replacement "simple-secret_123"
	[ "$status" -eq 0 ]
	[ "$output" = "simple-secret_123" ]
}

@test "escape_sed_replacement handles empty string" {
	run escape_sed_replacement ""
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
}

@test "sql_escape doubles single quotes" {
	run sql_escape "O'Reilly"
	[ "$status" -eq 0 ]
	[ "$output" = "O''Reilly" ]
}

@test "sql_escape escapes backslashes" {
	run sql_escape "a\b"
	[ "$status" -eq 0 ]
	[ "$output" = "a\\b" ]
}

@test "sql_escape leaves plain strings unchanged" {
	run sql_escape "plain_value"
	[ "$status" -eq 0 ]
	[ "$output" = "plain_value" ]
}

@test "sql_escape handles empty string" {
	run sql_escape ""
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
}
