# Anomalous Authentication Detection

**Source:** `mukul975/Anthropic-Cybersecurity-Skills` @ 7eebca88 — Apache 2.0
**Upstream skill:** `detecting-anomalous-authentication-patterns`
**NIST CSF:** DE.CM-01, DE.AE-02 | **MITRE ATT&CK:** T1078, T1110, T1621

## Purpose

Detect compromised credentials, credential stuffing, brute force, and session hijacking by applying statistical and behavioral baselines to authentication logs. High-signal: valid-account abuse (T1078) is the #1 attack pattern across cloud and web environments.

## Authentication Anomaly Patterns

### 1. Impossible Travel

Same account authenticates from two geographically distant locations within a time window that makes physical travel impossible.

```python
def is_impossible_travel(event1, event2, min_speed_kmh=900):
    """Flag if two auth events imply faster-than-possible travel"""
    import geopy.distance
    from datetime import datetime

    dist_km = geopy.distance.distance(
        (event1['lat'], event1['lon']),
        (event2['lat'], event2['lon'])
    ).km
    time_diff_h = abs((event2['timestamp'] - event1['timestamp']).total_seconds() / 3600)
    if time_diff_h < 0.01:  # Less than 36 seconds
        return True
    speed = dist_km / time_diff_h
    return speed > min_speed_kmh
```

**Detection trigger:** Log the event, block second login, force re-authentication.

### 2. Credential Stuffing (Distributed Brute Force)

Many accounts tried from many IPs — unlike single-account brute force, this is distributed across a botnet to evade per-IP rate limiting.

```sql
-- Detect: many different accounts, each with low failure count, across many IPs
SELECT account_id, COUNT(DISTINCT source_ip) AS ip_count, COUNT(*) AS attempts
FROM auth_events
WHERE result = 'FAILED'
  AND timestamp > NOW() - INTERVAL '15 minutes'
GROUP BY account_id
HAVING COUNT(*) > 3 AND COUNT(DISTINCT source_ip) > 2
ORDER BY attempts DESC;
```

**Detection trigger:** >10 accounts each with 2-5 failures from different IPs in 15min window = credential stuffing.

### 3. Account Compromise (Baseline Deviation)

Legitimate user behavioral baseline deviates significantly:

```python
def detect_behavioral_anomaly(user_event, user_baseline):
    anomalies = []

    # Time-of-day anomaly: login at unusual hour
    login_hour = user_event['timestamp'].hour
    if login_hour not in user_baseline['typical_hours']:
        anomalies.append(f"Unusual login hour: {login_hour}h (baseline: {user_baseline['typical_hours']})")

    # New device/browser
    if user_event['user_agent'] not in user_baseline['known_user_agents']:
        anomalies.append(f"New device: {user_event['user_agent']}")

    # New country
    if user_event['country'] not in user_baseline['known_countries']:
        anomalies.append(f"New country: {user_event['country']}")

    # Unusual data access pattern (volume spike)
    if user_event['data_accessed_mb'] > user_baseline['avg_daily_mb'] * 5:
        anomalies.append(f"Data access spike: {user_event['data_accessed_mb']}MB vs baseline {user_baseline['avg_daily_mb']}MB")

    return anomalies
```

**Response:** 2+ anomalies = MFA challenge; 3+ = force re-login + alert SOC.

### 4. OAuth Token Theft / Token Replay

```python
def detect_token_replay(token_usage_log):
    """Detect if a token is used from multiple IPs simultaneously"""
    from collections import defaultdict
    token_ips = defaultdict(set)
    for event in token_usage_log:
        token_ips[event['token_id']].add(event['source_ip'])

    for token_id, ips in token_ips.items():
        if len(ips) > 1:
            yield f"Token {token_id[:8]}... used from {len(ips)} IPs: {ips}"
```

### 5. MFA Fatigue (Push Bombing)

Attacker sends repeated MFA push notifications hoping user approves out of frustration.

**Detection:** ≥5 MFA push requests within 10 minutes for the same user.

```sql
SELECT user_id, COUNT(*) AS push_count
FROM mfa_events
WHERE event_type = 'PUSH_SENT'
  AND timestamp > NOW() - INTERVAL '10 minutes'
GROUP BY user_id
HAVING COUNT(*) >= 5;
```

**Response:** Temporarily disable push MFA, require TOTP or hardware token, alert user.

## Detection Thresholds (Starting Baselines)

| Pattern | Threshold | Action |
|---------|-----------|--------|
| Failed logins, single account | ≥5 in 5 min | Lock account temporarily |
| Failed logins, many accounts | >10 accounts with >2 failures each in 15 min | Rate limit by IP range |
| Impossible travel | Speed >900 km/h | Block + MFA challenge |
| New country + new device | Both true | Step-up authentication |
| MFA push requests | ≥5 in 10 min | Disable push, alert user |
| Token used from 2+ IPs | Any | Revoke token immediately |

## WALTEUR Integration

Auth logs from the application must be structured for this detection to work:
- Log every auth event: `{timestamp, user_id, result, source_ip, user_agent, country}`
- Ship to SIEM or structured log aggregator
- Sigma rules for auth anomalies live in `walteur-kit/rules/sigma/`

When the re-prosecutor finds a missing rate limiter or no MFA:
> **Attack path [T1110.004 / Credential Stuffing]:** Unauthenticated POST `/api/auth/login` with no rate limiting → attacker sends 10,000 credential pairs from botnet → valid credentials found, account compromised. Absent mitigation: no `express-rate-limit` on `/auth/login` (verified: no rate limit header in response).
