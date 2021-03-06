/* This function provides an interface for reporting events to sentry. Be aware that while it is
called "SentryClient" it is not a proper client as defined by the Sentry Unified API. Compliance with
the unified API is the long-term goal here, with the short-term goal of getting a working MVP.
   https://docs.sentry.io/development/sdk-dev/unified-api/
 */

CREATE OR REPLACE function SentryClient(
    dsn varchar2,   --DSN provided by Sentry. Currently ony supports old DSN format (with secret key)
    message varchar2,
    error_type varchar2,    --should be used for the whole error code, e.g. 'ORA-42069'
    error_value varchar2,   --should be used for the error message, e.g. 'rollback unsupported'
    module varchar2,    --
    stacktrace varchar2 := '',  --expected to be output from DBMS_UTILITY.FORMAT_ERROR_BACKTRACE
    extra_tags varchar2 := '',  --must be valid json map entries, including trailing comma (e.g. `"tag":"value","tag":"value",` )
    username varchar2 := '',    --optionally override username (in case DB is accessed through web server, like with Oracle Forms)
    ip_address varchar2 := '',  --optionally override IP (for same reason as username)
    errlevel varchar2 := 'warning') -- Valid values for level are: fatal, error, warning, info, debug
return
    varchar2    --if successful, returns event id. Otherwise returns null
as
    client varchar2(50) := 'sentry-plsql';
    version varchar2(10) := '1.0';
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
    event_username varchar2(500);
    event_userip varchar2(500);

    sentry_auth varchar2(2000);

    payload CLOB := '
    {
      "event_id": "$event_id",
      "logger": "$logger",
      "timestamp": "$timestamp",
      "message": "$message",
      "platform": "plsql",
      "server_name": "$servername",
      "level": "$level",
      "tags": {
        $extra_tags
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

    -- Set up data
    if stacktrace is not null and length(stacktrace) > 0 then
        --parse stacktrace into json (this is very hacky and doesn't produce good results)
        stacktrace_json := replace(stacktrace, '"', '''');  --replace double quotes with single, because json uses double
        stacktrace_json := replace(stacktrace_json, '\', '/');  --replace backslashes because they mess up json parsing
        stacktrace_json := substr(stacktrace_json, 0, length(stacktrace_json)-1); --last char is always newline
        stacktrace_json := replace(stacktrace_json, chr(10), '},{"'); --replace newlines with commas and curlies
        stacktrace_json := replace(stacktrace_json, 'ORA-06512', 'function":"ORA-06512'); --prepend with property name
        stacktrace_json := replace(stacktrace_json, ' line ', '","lineno":'); --prepend with property name
        stacktrace_json := '{"' || stacktrace_json || '}';   --wrap in double quotes
    else
        stacktrace_json := '{}';
    end if;

    select banner into dbversion from v$version where banner like 'Oracle%';
    event_id := lower(SYS_GUID());

    if username is not null then
        event_username := username;
    else
        event_username := SYS_CONTEXT('USERENV','OS_USER');
    end if;

    if ip_address is not null then
        event_userip := ip_address;
    else
        event_userip := SYS_CONTEXT('USERENV','IP_ADDRESS');
    end if;

    -- fill payload
    payload:=replace(payload, '$event_id', event_id);
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

    payload:=replace(payload, '$username', event_username);
    payload:=replace(payload, '$ip_address', event_userip);

    --replace user-provided values last, in case they happen to include one of the other template strings
    payload:=replace(payload, '$extra_tags', replace(extra_tags, '\', '/'));
    payload:=replace(payload, '$stacktrace', stacktrace_json);

    payload:=replace(payload, chr(13), ''); --trim newline chars from payload
    payload:=replace(payload, chr(10), '');
    payload:=ltrim(rtrim(payload));

    --compress payload
    declare
        tempBlob blob;
        dest_offset integer := 1;
        src_offset integer := 1;
        lang_context integer := 0;
        warning varchar2(4000);
    begin
        dbms_lob.createTemporary(tempBlob, true);
        dbms_lob.convertToBlob(tempBlob, payload, dbms_lob.getLength(payload), dest_offset, src_offset, 0, lang_context, warning);
        payload_compressed := utl_compress.lz_compress(tempBlob);
        dbms_lob.freeTemporary(tempBlob);
    end;

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

    begin
        loop
          utl_http.read_line(res, buffer);
          dbms_output.put_line(buffer);
        end loop;

        utl_http.end_response(res);

    exception
        when utl_http.end_of_body then
        utl_http.end_response(res);
    end;

    if res.status_code = utl_http.HTTP_OK then
        return event_id;
    else
        return null;
    end if;
end;
/
