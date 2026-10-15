use super::*;

fn endpoint(hub: &str, port: u32) -> Endpoint {
    Endpoint::new(&format!("USB#{hub}#FIXTURE{HUB_SUFFIX}"), port).unwrap()
}

#[test]
fn reciprocal_speed_ports_have_the_same_pinned_connector_location() {
    let high = endpoint("ROOT_HUB30", 10);
    let super_speed = endpoint("ROOT_HUB30", 26);
    let query = |input: &Endpoint| {
        Ok(Some(if input == &high {
            super_speed.clone()
        } else {
            high.clone()
        }))
    };
    assert_eq!(location(&high, query).unwrap(), 3_379_333_601);
    assert_eq!(location(&super_speed, query).unwrap(), 3_379_333_601);
    assert_eq!(
        location(&endpoint("ROOT_HUB20", 3), |_| Ok(None)).unwrap(),
        2_624_811_488
    );
    assert_ne!(
        location(&endpoint("ROOT_HUB30", 11), |_| Ok(None)).unwrap(),
        3_379_333_601
    );
    assert_ne!(
        location(&endpoint("OTHER_HUB", 10), |_| Ok(None)).unwrap(),
        3_379_333_601
    );
}

#[test]
fn a_missing_reverse_changing_route_or_self_companion_is_refused() {
    let a = endpoint("ROOT_HUB30", 10);
    let b = endpoint("ROOT_HUB30", 26);
    assert!(location(&a, |_| Ok(Some(a.clone()))).is_err());
    assert!(location(&a, |input| Ok((input == &a).then(|| b.clone()))).is_err());
    let mut calls = 0;
    assert!(
        location(&a, |input| {
            calls += 1;
            Ok(if calls > 2 {
                None
            } else if input == &a {
                Some(b.clone())
            } else {
                Some(a.clone())
            })
        })
        .is_err()
    );
    assert!(location(&a, |_| Err(invalid("OS query failed"))).is_err());
}

fn response(port: u32, other: Option<&Endpoint>) -> Vec<u8> {
    let mut bytes = vec![0; 16];
    bytes[..4].copy_from_slice(&port.to_le_bytes());
    if let Some(other) = other {
        bytes[14..16].copy_from_slice(&(other.port as u16).to_le_bytes());
        bytes.extend(other.hub.encode_utf16().flat_map(u16::to_le_bytes));
    }
    bytes.extend([0, 0]);
    let size = bytes.len() as u32;
    bytes[4..8].copy_from_slice(&size.to_le_bytes());
    bytes
}

#[test]
fn connector_bytes_refuse_ambiguous_malformed_or_mismatched_responses() {
    let other = endpoint("ROOT_HUB30", 26);
    let good = response(10, Some(&other));
    assert_eq!(companion(&good, 10).unwrap(), Some(other));
    assert_eq!(companion(&response(10, None), 10).unwrap(), None);
    assert!(companion(&good, 11).is_err());
    for (offset, value) in [(8, 4), (8, 16), (12, 1), (14, 0), (4, 17)] {
        let mut changed = good.clone();
        changed[offset] = value;
        assert!(
            companion(&changed, 10).is_err(),
            "offset {offset}, value {value}"
        );
    }
    for size in [0, 8, 17, good.len() - 1] {
        assert!(companion(&good[..size], 10).is_err());
    }
    let mut trailing = good.clone();
    trailing.push(1);
    assert!(companion(&trailing, 10).is_err());
    for path in ["", "file://hub", "USB#BAD\\PATH", "USB#BAD\0PATH"] {
        assert!(Endpoint::new(path, 10).is_err());
    }
    assert!(Endpoint::new(&endpoint("ROOT_HUB30", 10).hub, 0).is_err());
}
