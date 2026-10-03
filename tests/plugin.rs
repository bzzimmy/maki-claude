use std::path::Path;
use std::sync::Arc;

use maki_agent::tools::ToolRegistry;
use maki_lua::{PluginHost, PluginPermissions};
use maki_providers::{Timeouts, plugin};
use maki_storage::StateDir;
use maki_storage::auth::save_plugin_auth;
use serde_json::json;

const PLUGIN_NAME: &str = "maki-claude";
const SLUG: &str = "claude";
const DISPLAY_NAME: &str = "Claude subscription";
const MODEL_SPEC: &str = "claude/claude-opus-5";
const NET_HOST: &str = "api.anthropic.com";
const ACCESS: &str = "access-token";
const FAR_FUTURE_S: u64 = 4102444800;
const LOGIN_HINT: &str = "maki auth login claude";

/// The provider registry and the environment are global, so every test leans
/// on nextest running it in a process of its own.
fn plugin_host() -> PluginHost {
    let dir = std::env::temp_dir().join(format!("maki-claude-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    for var in [
        "HOME",
        "XDG_CONFIG_HOME",
        "XDG_DATA_HOME",
        "XDG_STATE_HOME",
        "XDG_CACHE_HOME",
    ] {
        unsafe { std::env::set_var(var, &dir) };
    }
    let host = PluginHost::new(Arc::new(ToolRegistry::new())).unwrap();
    let mut permissions = PluginPermissions::from_approved(["net", "run", "env"]);
    permissions.set_net_hosts(Some(Arc::from(vec![NET_HOST.to_owned()])));
    host.load_package(
        PLUGIN_NAME,
        Path::new(env!("CARGO_MANIFEST_DIR")),
        permissions,
        Default::default(),
    )
    .unwrap();
    plugin::commit_load();
    host
}

#[test]
fn registers_a_login_provider_with_the_anthropic_catalog() {
    let _host = plugin_host();
    assert!(plugin::auth_providers().contains(&(SLUG.to_owned(), DISPLAY_NAME.to_owned())));
    assert!(plugin::plugin_model_specs_for(SLUG).contains(&MODEL_SPEC.to_owned()));
}

#[test]
fn a_stored_token_becomes_the_bearer_header() {
    let _host = plugin_host();
    let creds = json!({ "access": ACCESS, "refresh": "refresh-token", "expires": FAR_FUTURE_S });
    save_plugin_auth(
        &StateDir::resolve().unwrap(),
        SLUG,
        creds.as_object().unwrap(),
    )
    .unwrap();

    let provider = plugin::create(SLUG, Timeouts::default()).unwrap();
    smol::block_on(provider.reload_auth()).unwrap();

    let headers = plugin::resolved_auth(SLUG).unwrap().headers;
    assert!(
        headers
            .iter()
            .any(|(k, v)| k.eq_ignore_ascii_case("authorization")
                && v == &format!("Bearer {ACCESS}")),
        "{headers:?}"
    );
}

#[test]
fn auth_without_a_login_names_the_login_command() {
    let _host = plugin_host();
    let failure = match plugin::create(SLUG, Timeouts::default()) {
        Ok(provider) => smol::block_on(provider.reload_auth()).unwrap_err(),
        Err(err) => err,
    };
    assert!(failure.to_string().contains(LOGIN_HINT), "{failure}");
}
