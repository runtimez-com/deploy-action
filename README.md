# runtimez-deploy-action

A reusable **GitHub composite Action** that builds your application
(Cloud Native Buildpacks or a Dockerfile), runs **tests + coverage**, scans for
vulnerabilities (**SCA via Trivy**) and code quality (**SAST via SonarQube**),
pushes the image to your container registry, and reports everything back to the
**runtimez control plane**.

It is the low-cost path: every tool used is free / open source
(`pack`, Trivy, sonar-scanner).

## What it does (in order)

1. **report-start** — `POST {runtimez-url}/eac/api/ci/runs` → opens a run, captures `runId`.
2. **build** — `docker buildx build` if a Dockerfile is given/present, else `pack build` (buildpacks auto-detect the language/runtime — no runtime input needed).
3. **test** — auto-detects the project and runs tests + coverage (JUnit XML + coverage XML).
4. **scan** — Trivy (SCA) on the image + sonar-scanner (SAST), polling the Sonar CE task for the `analysisId`.
5. **parse-results** — parses JUnit/coverage XML and Trivy JSON into the runtimez ingest shape.
6. **push** — `docker login` + `docker push`.
7. **report-results** — `POST {runId}/results` with test/coverage/quality summaries (+ Sonar measures, + raw payloads).
8. **report-deploy-intent** — `POST {runId}/deploy-intent` with `imageRef`/`imageTag` to queue the rollout.

The `runId` from step 1 threads through steps 7–8. The action is self-contained
and idempotent per job — re-running a job produces the same image tag (the short
git SHA) and re-reports against a fresh run.

## Usage

Add a workflow like the one below (this is the ~15-line snippet that the runtimez
backend auto-generates and commits into consumer repos). The full version is in
[`examples/runtimez-deploy.yml`](examples/runtimez-deploy.yml).

```yaml
- name: Build, test, scan, push and report to runtimez
  uses: runtimez/runtimez-deploy-action@v1
  with:
    runtimez-url: https://app.runtimez.io
    token: ${{ secrets.RUNTIMEZ_CI_TOKEN }}
    registry-host: ghcr.io
    image-repo: ${{ github.repository }}
    registry-username: ${{ github.actor }}
    registry-password: ${{ secrets.GITHUB_TOKEN }}
    sonar-host: https://sonar.runtimez.io
    sonar-token: ${{ secrets.SONAR_TOKEN }}
    sonar-project-key: my-org_my-app
```

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `runtimez-url` | yes | — | Base URL of the runtimez control plane. |
| `token` | yes | — | runtimez CI token (`rci_` prefixed). Pass `${{ secrets.RUNTIMEZ_CI_TOKEN }}`. |
| `registry-host` | yes | — | Registry host (e.g. `ghcr.io`, an ECR host). |
| `image-repo` | yes | — | Image repository path within the registry (e.g. `acme/web`). |
| `registry-username` | yes | — | Username for `docker login`. |
| `registry-password` | yes | — | Password/token for `docker login`. |
| `dockerfile-path` | no | `""` | Path to a Dockerfile. Empty ⇒ use buildpacks. |
| `buildpack-builder` | no | `paketobuildpacks/builder-jammy-base` | Builder image when no Dockerfile is used. |
| `test-command` | no | `""` | Override the auto-detected test command. |
| `sonar-host` | no | `https://sonar.runtimez.io` | SonarQube host URL. |
| `sonar-token` | no | `""` | SonarQube token. Empty ⇒ SAST is skipped. |
| `sonar-project-key` | no | `""` | SonarQube project key. Empty ⇒ SAST is skipped. |

## Outputs

| Output | Description |
|--------|-------------|
| `run-id` | The runtimez run id created in step 1. |
| `image-ref` | The full image reference built and pushed (`<host>/<repo>:<short-sha>`). |
| `image-tag` | The image tag (short git SHA). |

## Test auto-detection

| Detected file | Command | JUnit / coverage |
|---------------|---------|------------------|
| `pom.xml` | `mvn -B test` + jacoco report | surefire XML / `jacoco.xml` |
| `build.gradle*` | `./gradlew test jacocoTestReport` | `build/test-results` / jacoco XML |
| `package.json` | `npm ci && npm test` | `jest-junit` / cobertura |
| `go.mod` | `go test -json ./… \| go-junit-report` | go-junit XML / `gocover-cobertura` |
| `pyproject.toml` / `requirements.txt` | `pytest --junitxml --cov --cov-report=xml` | pytest JUnit / coverage XML |
| none | — | zero tests, continue |

Set `test-command` to override; the action still looks for the common JUnit/coverage
output locations.

## Prerequisites

The action expects these tools on `PATH`. On GitHub-hosted `ubuntu-latest` runners,
Docker is preinstalled; add setup steps for the rest **before** this action:

```yaml
- uses: docker/setup-buildx-action@v3
- uses: buildpacks/github-actions/setup-pack@v5.8.11     # provides `pack`
- run: curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin
- uses: SonarSource/sonarqube-scan-action@v4             # provides `sonar-scanner`
```

`python3`, `curl`, and `bash` are already present on GitHub-hosted runners.
If `trivy` or `sonar-scanner` are absent the action logs a warning and skips that
scan rather than failing the build. Any **non-2xx from the runtimez control plane**
fails the step with the response body printed.

## Versioning — the `v1` floating tag

Consumers pin `@v1` (a floating major tag). Each release is cut as a precise
`vX.Y.Z` tag (the first being `v1.0.0`); the `v1` tag is then **force-moved** to
point at the latest `v1.x.y` so consumers automatically pick up backward-compatible
fixes without changing their workflow:

```bash
git tag -fa v1 -m "v1 -> v1.2.3"
git push origin v1 --force   # done by maintainers when publishing
```

Breaking changes ship under a new floating major (`v2`). Pin `@v1.0.0` instead of
`@v1` if you need an immutable reference.

## License

[Apache-2.0](LICENSE).
