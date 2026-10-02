default:
    @just --list

check:
    cargo check --tests

lint:
    cargo clippy --tests -- -D warnings

test:
    cargo nextest run

fmt-lua:
    stylua plugin/
