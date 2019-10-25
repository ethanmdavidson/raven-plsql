CREATE OR REPLACE procedure SYS.RavenClient(
    dsn varchar2,
    message varchar2,
    errlevel varchar2 := 'warning') -- Valid values for level are: fatal, error, warning, info, debug
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
    name varchar2(500);
    buffer varchar2(4000);
    dbversion varchar2(2000);

    sentry_auth varchar2(2000);

    payload varchar2(4000) := '
    {
      "event_id": "$gui",
      "culprit": "$culprit",
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
      "exception": [
        {
          "type": "Error type",
          "value": "Error value",
          "module": "Module"
        }
      ]
    }';

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

    -- Extract Oracle Version
    select banner into dbversion from v$version where banner like 'Oracle%';

    payload:=replace(payload, '$gui', lower(SYS_GUID()));
    payload:=replace(payload, '$culprit', client);
    payload:=replace(payload, '$timestamp', to_char(sysdate, 'YYYY-MM-DD HH24:MI:SS'));
    payload:=replace(payload, '$message', message);
    payload:=replace(payload, '$servername', sys_context('USERENV','SERVER_HOST'));
    payload:=replace(payload, '$level', errlevel);

    payload:=replace(payload, '$dbversion', dbversion);
    payload:=replace(payload, '$oraclesid', sys_context('USERENV','SID'));
    payload:=replace(payload, '$current_schema', sys_context('USERENV','CURRENT_SCHEMA'));

    payload:=replace(payload, chr(13), '');
    payload:=replace(payload, chr(10), '');
    payload:=ltrim(rtrim(payload));

    -- Compose header
    sentry_auth := 'Sentry sentry_version=5,'||
                   'sentry_client=$client'||
                   'sentry_timestamp=$sentry_time,'||
                   'sentry_key=$sentry_public,'||
                   'sentry_secret=$sentry_secret';
    sentry_auth:= replace(sentry_auth, '$client', client||'/'||version
    sentry_auth:=replace(sentry_auth, '$sentry_time', replace(to_char( SYS_EXTRACT_UTC(SYSTIMESTAMP),'YYYY-MM-DD HH24:MI:SS'),' ','T'));
    sentry_auth:=replace(sentry_auth, '$sentry_key', publickey);
    sentry_auth:=replace(sentry_auth, '$sentry_secret', secretkey);


    -- Compose request
    req := utl_http.begin_request(url, 'POST',' HTTP/1.1');
    utl_http.set_header(req, 'User-agent', client||'/'||version);
    utl_http.set_header(req, 'payload-Type', 'application/json;charset=UTF-8');
    utl_http.set_header(req, 'Accept', 'application/json');
    utl_http.set_header(req, 'X-Sentry-Auth', sentry_auth);
    utl_http.set_header (req, 'Content-Length', lengthb(payload));
    utl_http.write_raw(req, utl_raw.cast_to_raw(payload));

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
end;
/
