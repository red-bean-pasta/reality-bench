# reality-benchmarker
A lightweight shell script that evaluates and scores candidate domains for the **Reality proxy protocol**, helping identify suitable camouflage domains.

## Background
Reality is a censorship-evasion proxy protocol that disguises itself as servers belonging to legitimate content providers.
For authentic client traffic, the server presents a temporary TLS certificate under the camouflage domain.
For invalid or probing packets, the server fetches the real certificate from the camouflage domain and forwards traffic accordingly.
Choosing an appropriate camouflage domain is therefore important for both reliability and stealth. This script automates the process of testing and benchmarking candidate domains.
___

## What the Script Checks
### Mandatory Requirements
These must be supported for Reality to function correctly or appear believable:
- TLS 1.3
- HTTP/2
- X25519 key exchange
- No redirection
### Preferred Features
These improve compatibility or realism but are optional:
- OCSP support
- TLS certificate fetching latency similarity
### Not Benchmarked
The following characteristics are intentionally not evaluated:
- IP similarity
Large services often operate across multiple subnets or networks.
- HTTP status code
Requests may legitimately target internal services or endpoints that do not return content.
- Port blocking & host server proxy behavior
Filtering and proxying behavior depends on user configuration rather than the properties of the target domain.

## Features
* Read domain lists from text or CSV files
* Benchmark TLS certificate fetching time against a user-defined reference address
___

## Usage
Example:
```bash
 bash ./benchmark_reality_candidates.sh -6 -c address.close.to.client -f test.csv -k domain_column -o result.txt more.domain.com www.domain.com
 ```
Show help with: 
```bash
bash ./benchmark_reality_candidates.sh -h
```
___

## TLS Certificate Fetching Benchmark
This script compares candidate domains with a user-provided reference address that should be geographically close to the client.
The goal is to estimate how realistic the TLS certificate fetching behavior appears.
### Workflow
* Measure TCP latency to the reference address using `tcping`
* Perform a TLS connection to the candidate domain
* Evaluate TLS handshake latency relative to the reference latency
### Formula
```bash
($tls_avg / 2) / ($tcp_avg + $tcp_span + 0.25 * ($tls_span / 2) + 10)
```
Where:
* `tls_avg` = average TLS handshake time
* `tls_span` = variation in TLS handshake time
* `tcp_avg` = average TCP latency to the reference host
* `tcp_span` = variation in TCP latency
___

# Scoring System
The maximum score is **100**.
If any mandatory requirement fails, the final score will be **0**.
| Category                               | Score |
| -------------------------------------- | ----- |
| TLS 1.3 + H2 + X25519 + No redirection | 50    |
| OCSP support                           | 25    |
| TLS certificate fetching time          | 25    |
