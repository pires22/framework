module framework;
import std::io;
import std::net;
import std::net::tcp;
import std::thread;
import libc;
import http;
import router;
import sv;

bool keepRunning = true;
TcpServerSocket! server_socket;

struct ClientArgs {
    Router* router;
    TcpSocket* client;
}

struct Framework {
    Router* router;
}

struct RouteGroup {
    String prefix;
    Framework* framework;
}

fn Framework* new_framework() {
    Framework* framework = mem::new(Framework);
    framework.router = router::new_router();
    return framework;
}

fn RouteGroup* Framework.new_route_group(&self, String prefix) {
    RouteGroup* route_group = mem::new(RouteGroup);
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

        ClientArgs* args = (ClientArgs*)mem::new(ClientArgs);
        args.router = self.router;
        args.client = &client_socket;

        if (catch reason = thread.create(&handle_client, (void*)args)) {
            io::printfn("thread creation failed: %s", reason);
            mem::free(args);
        } else {
            if (catch r = std::thread::Thread.detach(thread)) {
                io::printfn("thread detach failed: %s", r);
                mem::free(args);
            }
        }
    }
}

fn void sigint_handler(int sig_num) 
{
    keepRunning = false;
    io::printn("stopping application");
    if (catch reason = server_socket.close()) {
        io::printfn("failed to close server socket: %s", reason);
    }
    return;
}

fn void terminate(Request* request, TcpSocket* client, Router* router) {
    router.send_bad_request(client, request);
    close_client_socket(client);
    http::free_request(request);
}

fn int handle_client(void* arg) {
    ClientArgs* args = (ClientArgs*)arg;
    Router* router = args.router;
    TcpSocket* client = args.client;
    char[1024] buffer;
    bool read_buffer = true;
    bool should_close_connection = false;
    Poll[4] poll_set;
    poll_set[0].socket = client.sock;
    poll_set[0].events = std::net::SUBSCRIBE_ANY_READ;

    while(!should_close_connection) {
        Request* request = null;
        DString body = dstring::new();
        DString payload = dstring::new();
        while (read_buffer) {
            if (try poll_result = std::net::poll_ms(&poll_set, 30000)) {
                if (poll_result > 0) {
                    if (poll_set[0].revents & std::net::os::POLLIN) {
                        if (try usz read_size = client.read(&buffer)) {
                            if (try payload.write(&buffer)) {
                                io::printfn("buffer: %s", payload.str_view());
                                StringView request_data = sv::create_view(payload.str_view(), read_size);
                                if (request == null) {
                                    request = http::new_request();
                                    if (!request.parse_metadata(&request_data)) {
                                        terminate(request, client, router);
                                        return 0;
                                    }
                                    if (!request.parse_headers(&request_data)) {
                                        terminate(request, client, router);
                                        return 0;
                                    }
                                    if (!request.is_version_and_header_host_compliant()) {
                                        terminate(request, client, router);
                                        return 0;
                                    }
                                }
                                if (read_buffer) {
                                    body.append_chars(request_data.to_string());
                                    if (body.len() == 0 || body.str_view().ends_with("\r\n")) {
                                        read_buffer = false;
                                    }
                                }
                            }
                            payload.clear();
                        } else {
                            io::printn("failed to read from client");
                            close_client_socket(client);
                            break;
                        }

                    }
                } else if (poll_result == 0) {
                    io::printn("timeout, closing socket");
                    close_client_socket(client);
                    break;
                } else {
                    io::printn("poll error");
                    close_client_socket(client);
                    break;
                }
            }
        }
        if (request == null) {
            io::printn("connection aborted");
            break;
        }

        io::printfn("[%s] - %s", request.method, request.resource);
        if (!request.parse_body(body)) {
            router.send_bad_request(client, request);
            http::free_request(request);
            break;
        }
        router.handle_request(client, request);
        if (request.should_close_client()) {
            http::free_request(request);
            break;
        }

        read_buffer = true;
        body.clear();
    }
    mem::free(args);
    close_client_socket(client);
    return 0;
}

fn void close_client_socket(TcpSocket* client) {
    if (catch reason = client.close()) {
        io::printfn("failed to close client socket: %s", reason);
    }
}