//! Tiny semver compare: `MAJOR.MINOR.PATCH` with an optional `-pre` suffix.
//! A release outranks its own prerelease; prereleases compare dot-wise
//! (numeric parts numerically).

use std::cmp::Ordering;

fn parse(v: &str) -> Option<(Vec<u64>, Option<String>)> {
    let v = v.trim().trim_start_matches('v');
    let (core, pre) = match v.split_once('-') {
        Some((c, p)) => (c, Some(p.to_string())),
        None => (v, None),
    };
    let nums: Option<Vec<u64>> = core.split('.').map(|p| p.parse().ok()).collect();
    let nums = nums?;
    if nums.len() != 3 {
        return None;
    }
    Some((nums, pre))
}

/// `None` when either side is not a valid version.
pub fn compare(a: &str, b: &str) -> Option<Ordering> {
    let (an, ap) = parse(a)?;
    let (bn, bp) = parse(b)?;
    match an.cmp(&bn) {
        Ordering::Equal => {}
        o => return Some(o),
    }
    Some(match (ap, bp) {
        (None, None) => Ordering::Equal,
        (None, Some(_)) => Ordering::Greater,
        (Some(_), None) => Ordering::Less,
        (Some(x), Some(y)) => cmp_pre(&x, &y),
    })
}

fn cmp_pre(x: &str, y: &str) -> Ordering {
    let mut xi = x.split('.');
    let mut yi = y.split('.');
    loop {
        match (xi.next(), yi.next()) {
            (None, None) => return Ordering::Equal,
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(a), Some(b)) => {
                let o = match (a.parse::<u64>(), b.parse::<u64>()) {
                    (Ok(a), Ok(b)) => a.cmp(&b),
                    _ => a.cmp(b),
                };
                if o != Ordering::Equal {
                    return o;
                }
            }
        }
    }
}

pub fn is_newer(candidate: &str, than: &str) -> bool {
    compare(candidate, than) == Some(Ordering::Greater)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn orders() {
        assert!(is_newer("4.1.21", "4.1.20"));
        assert!(is_newer("4.10.0", "4.9.9"));
        assert!(!is_newer("4.1.20", "4.1.20"));
        assert!(is_newer("0.1.0", "0.1.0-beta.3"));
        assert!(is_newer("0.1.0-beta.10", "0.1.0-beta.9"));
        assert!(!is_newer("0.1.0-beta.1", "0.1.0"));
        assert_eq!(compare("garbage", "1.0.0"), None);
        assert!(is_newer("v1.0.1", "1.0.0"));
    }
}
