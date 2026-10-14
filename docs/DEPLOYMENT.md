# Deployment

## 1. Local (Anypoint Studio)
See [DEVELOPMENT-GUIDE.md](DEVELOPMENT-GUIDE.md) Part A.

## 2. Local (standalone Mule runtime)
```bash
cd invoice-system-api && mvn clean package -DskipMunitTests
cp target/invoice-system-api-1.0.0-mule-application.jar $MULE_HOME/apps/
# repeat for invoice-process-api and invoice-experience-api
$MULE_HOME/bin/mule -M-Denv=local
```

## 3. CloudHub 2.0

### 3.1 Prerequisites
- An Anypoint Platform account, an environment (e.g. `Sandbox`), and a target space (`Cloudhub-US-East-2` or a private space).
- A connected-app or user credentials in `~/.m2/settings.xml`:
```xml
<servers>
  <server>
    <id>anypoint-exchange-v3</id>
    <username>~~~Client~~~</username>
    <password>clientId~?~clientSecret</password>
  </server>
</servers>
```
- An internet-reachable MySQL (e.g. Amazon RDS) and an ERP endpoint. CloudHub cannot reach `localhost` or the Python mock unless you host it, for example on a small VM or container.

### 3.2 Configure
1. In each `pom.xml`, set `<groupId>` to your **Anypoint organization ID**. CloudHub 2.0 deploys from Exchange.
2. Encrypt the secrets with the Secure Properties Tool (AES/CBC, key of 16, 24 or 32 characters):
   ```bash
   java -cp secure-properties-tool.jar com.mulesoft.tools.SecurePropertiesTool string encrypt AES CBC <key> "<db password>"
   ```
   Paste each result as `![...]` into `src/main/resources/config/secure-prod.yaml`.
3. Hosts are set as deployment properties, for example `-Ddb.host=...`. They map to `DB_HOST` and the other variables in the `cloudhub` profile.

### 3.3 Deploy (System API first, then Process, then Experience)
```bash
cd invoice-system-api
mvn clean deploy -DmuleDeploy -Pcloudhub \
    -Danypoint.environment=Sandbox -Danypoint.target=Cloudhub-US-East-2 \
    -Dmule.key=<16-char-key> -Ddb.host=<rds-host> -Derp.host=<erp-host>
```
For the Process API pass `-Dsys.api.host=<system-api public or internal host>`. For the Experience API pass both `-Dprocess.api.host` and `-Dsys.api.host`.

Then, in Runtime Manager, confirm that `env=prod` and the secure properties are set. `mule-artifact.json` marks them as hidden.

### 3.4 Production hardening checklist
- [ ] Put the System and Process APIs in a **private space** or internal ingress only; expose only the Experience API.
- [ ] Replace in-app Basic auth with an **API Manager** policy (OAuth 2.0 / JWT validation) and in-app client checks with **Client ID Enforcement**.
- [ ] Add rate limiting and spike control on the Experience API.
- [ ] Move document storage from the local folder to S3 or Azure Blob (only `document-storage-config` changes).
- [ ] Set `file.flowState: stopped` (already the default in prod.yaml), or switch to the SFTP/S3 connector for drop folders.
- [ ] Rotate `INTERNAL_CLIENT_SECRET`, `PROCESS_API_CLIENT_SECRET`, `MOCK_AI_API_KEY` and the DB password; never reuse the local defaults.
- [ ] Anypoint Monitoring alerts: 5xx rate, `recovery.dead_letter`, average response time over 5s.

## 4. Monitoring

| Where | What |
|---|---|
| Runtime Manager > Logs | JSON events with correlation ids |
| Anypoint Monitoring | Built-in dashboards (requests, errors, CPU/memory), custom dashboards on log events |
| `GET /sys/v1/recovery-queue?status=DEAD` | Dead letters needing manual action |
| `database/03-useful-queries.sql` | Pipeline overview, audit trail, PO consumption |
