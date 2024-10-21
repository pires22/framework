module http;
import std::io;
import std::core::dstring;
import std::core::string;
import std::collections::list;
import std::net::tcp;
import std::collections::map;
import libc;
import sv;

def Handler = fn void! (Request* req, Response* res);

struct Request {
    String method;
    String resource;
    String version;
    Map(<String, String>)* headers;
    Map(<String, String>)* params;
    Map(<String, String>)* query_params;
    DString body;
}

struct Response {
    TcpSocket* client;
    bool sent;
    String version;
    uint status_code;
    String status_code_text;
    Map(<String, String>)* headers;
    String body;
}

fn Request* new_request() {
    Request* request = mem::new(Request);
    request.query_params = mem::new(Map(<String, String>));
    request.params = mem::new(Map(<String, String>));
    request.headers = mem::new(Map(<String, String>));

    return request;
}

fn Response* new_response(TcpSocket* client) {
    Response* response = mem::new(Response);
    response.client = client;
    response.headers = mem::new(Map(<String, String>));

    return response;
}

fn void Request.parse_resource(&self, String uri) {
    DString resource = std::core::dstring::new(uri);
    StringView resource_view = sv::create_view(resource.str_view(), resource.len());
    self.resource = resource_view.chop_by_delimiter('?').to_string().strip_end("/");
    if (resource_view.length > 0) {
        self.parse_query_string(resource_view);
    }
}

fn String decode_url(String url) {
    StringIterator iter = url.iterator();
    DString decoded_url = std::core::dstring::new();

    while (try uint c = iter.next()) {
        if (c == '%') {
            uint hex1 = iter.next()!!;
            uint hex2 = iter.next()!!;
            uint decoded_char = hex_to_char(hex1, hex2);
            decoded_url.append_char((char)decoded_char);
        } else if (c == '+') {
            decoded_url.append_char(' ');
        } else {
            decoded_url.append_char((char)c);
        }
    }

    return decoded_url.copy_str();
}

fn uint hex_to_char(uint hex1, uint hex2) {
    return (hex_value(hex1) << 4) | hex_value(hex2);
}

fn uint hex_value(uint c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'A' && c <= 'F') return 10 + (c - 'A');
    if (c >= 'a' && c <= 'f') return 10 + (c - 'a');
    return 0;
}

fn void Request.parse_metadata(&self, StringView* sv) {
    StringView metadata = sv.chop_by_delimiter('\n');
    self.method = metadata.chop_by_delimiter(' ').to_string().copy();
    self.parse_resource(decode_url(metadata.chop_by_delimiter(' ').to_string().copy()));
    self.version = metadata.to_string().copy();
}

fn void Request.parse_headers(&self, StringView* headers) {
    while(headers.length > 0) {
        StringView data = headers.chop_by_delimiter('\n');
        if (data.to_string() == "\r") {
            break;
        }
        StringView header_data = sv::create_from_string_view(&data);
        while(header_data.length > 0) {
            String header_name = header_data.chop_by_delimiter(' ').to_string().strip_end(":");
            String header_value = header_data.chop_by_delimiter('\n').to_string().trim();
            self.headers.set(header_name.new_ascii_to_lower(), header_value);
        }
    }
}

fn void Request.parse_body(&self, DString body) {
    if (self.headers.has_key("transfer-encoding")) {
        if (try transfer_encoding = self.headers.get("transfer-encoding")) {
            if (transfer_encoding == "chunked") {
                StringView body_sv = sv::create_view(body.str_view(), body.len());
                body_sv.chop_by_delimiter('\n');
                while (body_sv.length > 0) {
                    StringView chunk_size_line = body_sv.chop_by_delimiter('\n');
                    StringView chunk_size_str = chunk_size_line.chop_by_delimiter(';');
                    StringView chunk = body_sv.chop_by_delimiter('\n');
                    if (chunk_size_str.to_string().trim("\r") == "0" && chunk.to_string().trim() == "") {
                        break;
                    }
                    self.body.append_chars(chunk.to_string().trim());
                }
            }
        } else {
            io::printfn("failed to get transfer encoding header");
            // TODO: cancel request and close connection
        }
    } else {
        self.body.append_chars(body.str_view());
    }
}

fn bool Request.should_close_client(&self) {
    if (self.version == "HTTP/1.1") {
        if (try connection_header = self.headers.get("connection")) {
            if (connection_header == "close") {
                return true;
            }
        }
        return false;
    }
    return true;
}

fn bool Request.check_version_and_header_host_compliant(&self) {
    if (self.version == "HTTP/1.1") {
        if (try connection_header = self.headers.get("host")) {
            return true;
        }
        return false;
    }
    return true;
}

fn void Request.parse_query_string(&self, StringView query_string) {
    while (query_string.length > 0) {
        StringView pair = query_string.chop_by_delimiter('&');
        while (pair.length > 0) {
            String key = pair.chop_by_delimiter('=').to_string();
            String value = pair.to_string();
            self.query_params.set(key, value);
        }
    }
}

fn String Request.get_param(&self, String key) {
    if (!self.params.has_key(key)) {
        return "";
    }
    String! value = self.params.get(key);
    if (catch reason = value) {
        return "";
    }

    return value;
}

fn String Request.get_query_param(&self, String key) {
    if (!self.query_params.has_key(key)) {
        return "";
    }
    String! value = self.query_params.get(key);
    if (catch reason = value) {
        return "";
    }

    return value;
}

fn void Response.send(&self, String body = "") {
    self.make_response(body);
    DString data = assemble_response(self);
    if (self.client != null) {
        self.client.write(data.str_view())!!;
        data.free();
    }
    self.sent = true;
}

fn Response* Response.status(&self, uint status) {
    self.status_code = status;
    return self;
}

fn Response* Response.make_response(&self, String body) {
    self.version = "HTTP/1.0";
    self.body = body;
    return self;
}

fn DString assemble_response(Response* response) {
    DString status_code = uint_to_string(response.status_code);
    DString response_data = std::core::dstring::new_join(String[]{response.version, status_code.str_view(), response.status_code_text}, " ");
    status_code.free();
    response_data.append_chars("\r\n");
    response.headers.@each_entry(; Entry(<String, String>)* entry) {
        DString header_line = std::core::dstring::new_join(String[]{entry.key, entry.value}, ": ");
        header_line.append_chars("\r\n");
        response_data.append_string(header_line);
        header_line.free();
    };
    response_data.append_chars("\r\n");
    response_data.append_chars(response.body);
    return response_data;
}

fn void free_request(Request* request) {
    request.headers.free();
    request.query_params.free();

    mem::free(request);
}

fn void free_response(Response* response) {
    response.headers.free();
    mem::free(response);
}

fn DString uint_to_string(uint value) {
    char[32] buffer;
    usz i = 0;

    // Convert the number to string (handle zero case)
    if (value == 0) {
        buffer[i++] = '0';
    } else {
        while (value > 0) {
            char digit = (char)(value % 10);  // Get last digit
            buffer[i++] = '0' + digit;
            value /= 10;
        }
    }

    // Reverse the buffer
    for (usz j = 0; j < i / 2; j++) {
        char temp = buffer[j];
        buffer[j] = buffer[i - j - 1];
        buffer[i - j - 1] = temp;
    }

    DString result = std::core::dstring::new_with_capacity(i + 1);
    for (usz k = 0; k < i; k++) {
        result.append_char(buffer[k]);
    }

    return result;
}
