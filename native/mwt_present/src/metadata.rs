//! A cloud metadata server's answers, from a grant's placeholders. Pure, so
//! the routes are tested on their own.
//!
//! | Path                                                     | Answer |
//! |----------------------------------------------------------|--------|
//! | `/`                                                      | 200, `Metadata-Flavor: Google` |
//! | `…/project/project-id`                                   | the project id |
//! | `…/instance/service-accounts/`                           | `default/` and the email |
//! | `…/instance/service-accounts/ACCOUNT/`                   | JSON: email, scopes, aliases |
//! | `…/instance/service-accounts/ACCOUNT/token`              | JSON: the access token placeholder |
//! | `…/instance/service-accounts/ACCOUNT/email`, `/scopes`   | the email, the scopes |
//! | `…/universe/universe-domain`                             | `googleapis.com` |
//!
//! Every path but `/` needs the header `Metadata-Flavor: Google`, as the
//! real server does.

const PREFIX: &str = "/computeMetadata/v1";
const SCOPE: &str = "https://www.googleapis.com/auth/cloud-platform";

/// What it serves.
#[derive(Debug, Default, Clone)]
pub struct Config {
    pub token: String,
    pub project: String,
    pub email: String,
}

impl Config {
    /// From the grant's environment: `MWT_PRESENT_TOKEN`, `_PROJECT` and
    /// `_EMAIL`.
    pub fn from_env(get: impl Fn(&str) -> Option<String>) -> Config {
        Config {
            token: get("MWT_PRESENT_TOKEN").unwrap_or_default(),
            project: get("MWT_PRESENT_PROJECT").unwrap_or_default(),
            email: get("MWT_PRESENT_EMAIL")
                .filter(|email| !email.is_empty())
                .unwrap_or_else(|| "default".to_string()),
        }
    }
}

#[derive(Debug)]
pub struct Request {
    pub method: String,
    pub path: String,
    pub flavor: bool,
}

impl Request {
    pub fn parse(head: &[u8]) -> Option<Request> {
        let text = std::str::from_utf8(head).ok()?;
        let mut lines = text.split("\r\n");
        let mut first = lines.next()?.split(' ');
        let method = first.next()?.to_string();
        let target = first.next()?;
        let path = target
            .split_once('?')
            .map_or(target, |(path, _query)| path)
            .to_string();

        let flavor = lines.any(|line| {
            line.split_once(':').is_some_and(|(name, value)| {
                name.trim().eq_ignore_ascii_case("metadata-flavor") && value.trim() == "Google"
            })
        });

        Some(Request {
            method,
            path,
            flavor,
        })
    }
}

#[derive(Debug, PartialEq)]
pub struct Answer {
    pub status: u16,
    pub content_type: &'static str,
    pub body: String,
}

impl Answer {
    pub fn status(status: u16, body: &str) -> Answer {
        Answer {
            status,
            content_type: "text/plain",
            body: body.to_string(),
        }
    }

    fn text(body: String) -> Answer {
        Answer {
            status: 200,
            content_type: "application/text",
            body,
        }
    }

    fn json(body: String) -> Answer {
        Answer {
            status: 200,
            content_type: "application/json",
            body,
        }
    }

    pub fn bytes(&self) -> Vec<u8> {
        let reason = match self.status {
            200 => "OK",
            400 => "Bad Request",
            403 => "Forbidden",
            404 => "Not Found",
            405 => "Method Not Allowed",
            _ => "Error",
        };

        format!(
            "HTTP/1.1 {} {}\r\nMetadata-Flavor: Google\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            self.status,
            reason,
            self.content_type,
            self.body.len(),
            self.body
        )
        .into_bytes()
    }
}

pub fn route(request: &Request, config: &Config) -> Answer {
    if request.method != "GET" {
        return Answer::status(405, "only GET");
    }

    let path = request.path.trim_end_matches('/');

    if path.is_empty() {
        return Answer::text(String::new());
    }

    if !request.flavor {
        return Answer::status(403, "Missing Metadata-Flavor:Google header.");
    }

    let Some(rest) = path.strip_prefix(PREFIX) else {
        return Answer::status(404, "not found");
    };

    match rest {
        "/project/project-id" => Answer::text(config.project.clone()),
        "/universe/universe-domain" => Answer::text("googleapis.com".to_string()),
        "/instance/service-accounts" => Answer::text(format!("default/\n{}/\n", config.email)),
        _ => account(rest, config),
    }
}

fn account(rest: &str, config: &Config) -> Answer {
    let Some(tail) = rest.strip_prefix("/instance/service-accounts/") else {
        return Answer::status(404, "not found");
    };

    let (name, what) = tail.split_once('/').unwrap_or((tail, ""));

    if name != "default" && name != config.email {
        return Answer::status(404, "not found");
    }

    match what {
        "" => Answer::json(format!(
            "{{\"aliases\":[\"default\"],\"email\":{},\"scopes\":[\"{SCOPE}\"]}}",
            quoted(&config.email)
        )),
        "email" => Answer::text(config.email.clone()),
        "scopes" => Answer::text(format!("{SCOPE}\n")),
        "aliases" => Answer::text("default\n".to_string()),
        "token" => Answer::json(format!(
            "{{\"access_token\":{},\"expires_in\":600,\"token_type\":\"Bearer\"}}",
            quoted(&config.token)
        )),
        _ => Answer::status(404, "not found"),
    }
}

fn quoted(text: &str) -> String {
    let mut out = String::from("\"");

    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }

    out.push('"');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config() -> Config {
        Config::from_env(|name| match name {
            "MWT_PRESENT_TOKEN" => Some("ya29.mwt_placeholder".to_string()),
            "MWT_PRESENT_PROJECT" => Some("my-project".to_string()),
            "MWT_PRESENT_EMAIL" => Some("sa@my-project.iam.gserviceaccount.com".to_string()),
            _ => None,
        })
    }

    fn get(path: &str, flavor: bool) -> Answer {
        let path = path.split_once('?').map_or(path, |(path, _query)| path);
        route(
            &Request {
                method: "GET".to_string(),
                path: path.to_string(),
                flavor,
            },
            &config(),
        )
    }

    #[test]
    fn the_root_answers_without_the_header() {
        let answer = get("/", false);
        assert_eq!(answer.status, 200);
        assert!(String::from_utf8(answer.bytes())
            .unwrap()
            .contains("Metadata-Flavor: Google"));
    }

    #[test]
    fn every_other_path_needs_the_header() {
        assert_eq!(
            get("/computeMetadata/v1/project/project-id", false).status,
            403
        );
        assert_eq!(
            get("/computeMetadata/v1/project/project-id", true).body,
            "my-project"
        );
    }

    #[test]
    fn the_token_is_the_placeholder() {
        let answer = get(
            "/computeMetadata/v1/instance/service-accounts/default/token",
            true,
        );
        assert_eq!(
            answer.body,
            "{\"access_token\":\"ya29.mwt_placeholder\",\"expires_in\":600,\"token_type\":\"Bearer\"}"
        );
        assert_eq!(answer.content_type, "application/json");
    }

    #[test]
    fn the_account_by_alias_or_email() {
        let by_alias = get(
            "/computeMetadata/v1/instance/service-accounts/default/?recursive=true",
            true,
        );
        assert!(by_alias
            .body
            .contains("\"email\":\"sa@my-project.iam.gserviceaccount.com\""));
        assert!(by_alias.body.contains("\"aliases\":[\"default\"]"));

        let by_email = get(
            "/computeMetadata/v1/instance/service-accounts/sa@my-project.iam.gserviceaccount.com/email",
            true,
        );
        assert_eq!(by_email.body, "sa@my-project.iam.gserviceaccount.com");
        assert_eq!(
            get(
                "/computeMetadata/v1/instance/service-accounts/other/token",
                true
            )
            .status,
            404
        );
        assert_eq!(
            get("/computeMetadata/v1/universe/universe-domain", true).body,
            "googleapis.com"
        );
    }

    #[test]
    fn only_get_and_only_its_paths() {
        let mut request = Request::parse(b"POST / HTTP/1.1\r\n\r\n").unwrap();
        assert_eq!(route(&request, &config()).status, 405);
        request.method = "GET".to_string();
        request.path = "/latest/meta-data".to_string();
        request.flavor = true;
        assert_eq!(route(&request, &config()).status, 404);
    }
}
