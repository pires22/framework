module framework;
import std::io;
import std::net;
import std::net::tcp;
import std::core::mem;
import std::thread;
import libc;
import http;
import router;
import sv;

bool keepRunning = true;
TcpServerSocket! server_socket;

def PathHandler = fn void (Framework* app);

struct ClientArgs {
    Router* router;
    TcpSocket client;
}

struct Framework {
    Router* router;
}

struct RouteGroup {
    String prefix;
    Framework* framework;
}

fn Framework* new_framework() {
    Framework* framework = std::core::mem::new(Framework);
    framework.router = router::new_router();
    return framework;
}

fn RouteGroup* Framework.new_route_group(&self, String prefix) {
    RouteGroup* route_group = std::core::mem::new(RouteGroup);
    route_group.prefix = prefix;
    route_group.framework = self;
    return route_group;
}

fn void RouteGroup.get(&self, String path, Handler handler) {
    String full_path = self.prefix.concat(path);
    self.framework.get(full_path, handler);
}

fn void RouteGroup.post(&self, String path, Handler handler) {
    String full_path = self.prefix.concat(path);
    self.framework.post(full_path, handler);
}

fn void Framework.get(&self, String path, Handler handler) {
    self.router.add_route("GET", path, handler);
}

fn void Framework.post(&self, String path, Handler handler) {
    self.router.add_route("POST", path, handler);
}

fn void Framework.run(&self, String host = "localhost", int port = 8080) {
    libc::signal(libc::SIGINT, &sigint_handler);
    server_socket = net::tcp::listen(host, port, 1, SocketOption.REUSEADDR);
    if (catch reason = server_socket)
    {
        io::printfn("socket creation failed, reason: %s", reason);
        return;
    }

    io::printfn("app is listening on %s:%d", host, port);

    while (keepRunning) {
        TcpSocket! client_socket = net::tcp::accept(&server_socket);
        if (catch reason = client_socket)
        {
            if (reason != NetError.ACCEPT_FAILED) {
                io::printfn("failed to accept socket: %s", reason);
            }
            continue;
        }
        Thread thread;

        ClientArgs* args = (ClientArgs*)std::core::mem::new(ClientArgs);
        args.router = self.router;
        args.client = client_socket;

        if (catch reason = thread.create(&handle_client, (void*)args)) {
            io::printfn("Thread creation failed: %s", reason);
            std::core::mem::free(args);
        } else {
            if (catch r = std::thread::Thread.detach(thread)) {
                io::printfn("Thread detach failed: %s", r);
                std::core::mem::free(args);
            }
        }
    }
}

fn void sigint_handler(int sig_num) 
{
    keepRunning = false;
    io::printn("stopping");
    if (catch reason = server_socket.close()) {
        io::printfn("failed to close server socket: %s", reason);
    }
    return;
}

fn int handle_client(void* arg) {
    ClientArgs* args = (ClientArgs*)arg;
    Router* router = args.router;
    TcpSocket client = args.client;
    char[1024] buffer;
    bool keep_reading_buffer = true;
    Request* request;
    DString body = std::core::dstring::new();
    bool should_close = false;

    while(!should_close) {
        while (keep_reading_buffer) {
            Poll[4] poll_set;
            poll_set[0].socket = client.sock;
            poll_set[0].events = std::net::SUBSCRIBE_ANY_READ;

            if (try poll_result = std::net::poll_ms(&poll_set, 30000)) {
                if (poll_result > 0) {
                    if (poll_set[0].revents & std::net::os::POLLIN) {
                        if (try usz read_size = client.read(&buffer)) {
                            DString payload = std::core::dstring::new_with_capacity(read_size);
                            if (try payload.write(&buffer)) {
                                StringView request_data = sv::create_view(payload.str_view(), read_size);
                                if (request == null) {
                                    request = http::new_request();
                                    request.parse_metadata(&request_data);
                                    request.parse_headers(&request_data);
                                    if (!request.check_version_and_header_host_compliant()) {
                                        // HTTP/1.1 but dont have Host header
                                        // TODO: send response with bad request
                                        keep_reading_buffer = false;
                                        should_close = true;
                                    }
                                }
                                if (keep_reading_buffer) {
                                    body.append_chars(request_data.to_string());
                                    if (body.len() == 0 || body.copy_str().ends_with("\r\n")) {
                                        keep_reading_buffer = false;
                                    }
                                }
                            }
                        } else {
                            io::printfn("failed to read from client");
                            if (catch r = client.close()) {
                                io::printfn("failed to close client socket: %s", r);
                            }
                            std::core::mem::free(args);
                            return 1;
                        }

                    }
                } else if (poll_result == 0) {
                    io::printfn("timeout, closing socket");
                    if (catch r = client.close()) {
                        io::printfn("failed to close client socket: %s", r);
                    }
                    std::core::mem::free(args);
                    return 1;
                } else {
                    io::printfn("poll error");
                    if (catch r = client.close()) {
                        io::printfn("failed to close client socket: %s", r);
                    }
                    std::core::mem::free(args);
                    return 1;
                }
            }

        }

        request.parse_body(body);
        router::handle_request(client, router, request);
        http::free_request(request);

        if (request.should_close_client()) {
            should_close = true;
        }

        body.clear();
    }

    if (catch reason = client.close()) {
        io::printfn("failed to close client socket: %s", reason);
    }

    body.free();
    std::core::mem::free(args);
    return 0;
}