/* This function provides an interface for reporting events to sentry. Be aware that while it is
called "RavenClient" it is not a proper client as defined by the Sentry Unified API. Compliance with
the unified API is the long-term goal here, with the short-term goal of getting a working MVP.
   https://docs.sentry.io/development/sdk-dev/unified-api/
 */

CREATE OR REPLACE function SYS.RavenClient(
    dsn varchar2,           --DSN provided by Sentry. Currently ony supports old DSN format (with secret key)
    message varchar2,
    error_type varchar2,    --should be used for the whole error code, e.g. 'ORA-42069'
    error_value varchar2,   --should be used for the error message, e.g. 'rollback unsupported'
    module varchar2,        --
    stacktrace varchar2,    --expected to be output from DBMS_UTILITY.FORMAT_ERROR_BACKTRACE
    errlevel varchar2 := 'warning') -- Valid values for level are: fatal, error, warning, info, debug
return
    varchar2    --if successful, returns event id. Otherwise returns null
as
    client varchar2(50) := 'raven-oracle';
    version varchar2(10) := '1.1';
    req utl_http.req;
    res utl_http.resp;
    protocol varchar2(10);
    publickey varchar2(255);
    secretkey varchar2(255);
    hostpath varchar2(500);
    projectid varchar2(255);
    url varchar2(4000);
    buffer varchar2(4000);
    dbversion varchar2(2000);
    event_id varchar2(32);
    stacktrace_json varchar2(4000);

    sentry_auth varchar2(2000);

    --payload should probably be a lob
    payload varchar2(4000) := '
    {
      "event_id": "$gui",
      "logger": "$logger",
      "timestamp": "$timestamp",
      "message": "$message",
      "platform": "plsql",
      "server_name": "$servername",
      "level": "$level",
      "tags": {
        "oracle_version": "$dbversion",
        "sid": "$oraclesid",
        "current_schema": "$current_schema"
      },
      "exception": {
        "type": "$error_type",
        "value": "$error_value",
        "module": "$module",
        "stacktrace": {
          "frames": [$stacktrace]
        }
      },
      "user":{
        "id": "$username",
        "username": "$username",
        "ip_address": "$ip_address"
      }
    }';
    payload_compressed blob := to_blob('1');

    i number;
    j number;
begin
    -- Parse DSN
    i := 0;
    j := instr(dsn, '://')-1;
    protocol := substr(dsn, i, j);
    i := j+4;
    j := instr(dsn, ':', i);
    publickey := substr(dsn, i, j-i);
    i := j + 1;
    j := instr(dsn, '@', i);
    secretkey := substr(dsn, i, j-i);
    i := j + 1;
    j := instr(dsn, '/', i);
    hostpath := substr(dsn, i, j-i);
    projectid := substr(dsn, j+1);

    url := protocol || '://' || hostpath || '/api/' || projectid || '/store/';

    --parse stacktrace into json (this is very hacky and doesn't produce good results)
    stacktrace_json := replace(stacktrace, '"', '''');  --replace double quotes with single, because json uses double
    stacktrace_json := substr(stacktrace_json, 0, length(stacktrace_json)-1); --last char is always newline
    stacktrace_json := replace(stacktrace_json, chr(10), '},{"'); --replace newlines with commas and curlies
    stacktrace_json := replace(stacktrace_json, 'ORA-06512', 'function":"ORA-06512'); --prepend with property name
    stacktrace_json := replace(stacktrace_json, ' line ', '","lineno":'); --prepend with property name
    stacktrace_json := '{"' || stacktrace_json || '}';   --wrap in double quotes

    -- Extract Oracle Version
    select banner into dbversion from v$version where banner like 'Oracle%';

    event_id := lower(SYS_GUID());

    payload:=replace(payload, '$gui', event_id;
    payload:=replace(payload, '$logger', client);
    payload:=replace(payload, '$timestamp', replace(to_char(SYS_EXTRACT_UTC(SYSTIMESTAMP),'YYYY-MM-DD HH24:MI:SS'),' ','T'));
    payload:=replace(payload, '$message', message);
    payload:=replace(payload, '$servername', sys_context('USERENV','SERVER_HOST'));
    payload:=replace(payload, '$level', errlevel);

    payload:=replace(payload, '$dbversion', dbversion);
    payload:=replace(payload, '$oraclesid', sys_context('USERENV','SID'));
    payload:=replace(payload, '$current_schema', sys_context('USERENV','CURRENT_SCHEMA'));

    payload:=replace(payload, '$error_type', error_type);
    payload:=replace(payload, '$error_value', error_value);
    payload:=replace(payload, '$module', module);
    payload:=replace(payload, '$stacktrace', stacktrace_json);

    payload:=replace(payload, '$username', SYS_CONTEXT('USERENV','OS_USER'));
    payload:=replace(payload, '$ip_address', SYS_CONTEXT('USERENV','IP_ADDRESS'));

    payload:=replace(payload, chr(13), ''); --trim newline chars from payload
    payload:=replace(payload, chr(10), '');
    payload:=ltrim(rtrim(payload));

    utl_compress.lz_compress(src=> to_blob(utl_raw.cast_to_raw(payload)), dst=> payload_compressed);

    -- Compose header
    sentry_auth := 'Sentry sentry_version=7,'||
                   'sentry_client=$sentry_client,'||
                   'sentry_timestamp=$sentry_time,'||
                   'sentry_key=$sentry_key,'||
                   'sentry_secret=$sentry_secret';
    sentry_auth:= replace(sentry_auth, '$sentry_client', client||'/'||version);
    sentry_auth:=replace(sentry_auth, '$sentry_time', replace(to_char(SYS_EXTRACT_UTC(SYSTIMESTAMP),'YYYY-MM-DD HH24:MI:SS'),' ','T'));
    sentry_auth:=replace(sentry_auth, '$sentry_key', publickey);
    sentry_auth:=replace(sentry_auth, '$sentry_secret', secretkey);

    -- Compose request
    req := utl_http.begin_request(url, 'POST',' HTTP/1.1');
    utl_http.set_header(req, 'User-agent', client||'/'||version);
    utl_http.set_header(req, 'payload-Type', 'application/json;charset=UTF-8');
    utl_http.set_header(req, 'Accept', 'application/json');
    utl_http.set_header(req, 'X-Sentry-Auth', sentry_auth);
    utl_http.set_header(req, 'Content-Encoding', 'gzip');
    utl_http.set_header (req, 'Content-Length', DBMS_LOB.getlength(payload_compressed));
    utl_http.write_raw(req, payload_compressed);

    -- debug messages
    -- dbms_output.put_line(sentry_auth);
    -- dbms_output.put_line(payload);

    res := utl_http.get_response(req);

    if res.status_code = utl_http.HTTP_OK then
        return event_id;
    else
        return null;
    end if;

    /*begin
        loop
          utl_http.read_line(res, buffer);
          dbms_output.put_line(buffer);
        end loop;

        utl_http.end_response(res);

    exception
        when utl_http.end_of_body then
        utl_http.end_response(res);
    end;*/
end;
/
