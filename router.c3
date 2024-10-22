module router;
import std::collections::list;
import std::collections::map;
import std::io;
import std::net::tcp;
import http;
import sv;

struct Route {
    String method;
    String path;
    Handler handler;
}

struct Router {
    List(<Route*>) routes;
}

fn Router* new_router() {
    Router* router = mem::new(Router);
    return router;
}

fn void Router.add_route(&self, String method, String path, Handler handler) {
    if (method == "") {
		io::printn("method must not be empty");
        return;
	}
	if (path.len < 1 || path[0] != '/') {
		io::printfn("path must begin with '/' in path %s", path);
        return;
	}
	if (handler == null) {
		io::printn("handler must not be nil");
        return;
	}

    Route* route = mem::new(Route);
    route.method = method;
    route.path = path.strip_end("/");
    route.handler = handler;

    self.routes.push(route);
}

fn bool match_route(String route_pattern, Request* request) {
    StringView pattern_sv = sv::create_view(route_pattern, route_pattern.len);
    StringView resource_sv = sv::create_view(request.resource, request.resource.len);
    if (pattern_sv.count_occurrences('/') != resource_sv.count_occurrences('/')) {
        return false;
    }
    while(pattern_sv.length > 0) {
        String pattern = pattern_sv.chop_by_delimiter('/').to_string();
        String path = resource_sv.chop_by_delimiter('/').to_string();
        if (pattern.starts_with("{") && pattern.ends_with("}")) {
            String param_name = pattern.strip("{").strip_end("}");
            request.params.set(param_name, path);
        } else if (pattern != path) {
            return false;
        }
    }
    return true;
}

fn Route* Router.router_match_route(&self, Request* req) {
    for (usz i = 0; i < self.routes.len(); i++) {
        foreach (Route* route : self.routes)
        {
            if (route.method == req.method && match_route(route.path, req)) {
                return route;
            }
        }
    }
    return null;
}

fn void Router.handle_request(&self, TcpSocket* client, Request* request) {
    Route* route = self.router_match_route(request);
    if (route != null) {
        Response* response = http::new_response(client);
        response.status(200);
        if (route.handler == null) {
            response.status(404).send("Not found");
        } else {
            if (catch exception = route.handler(request, response)) {
                response.status(500).send("Internal server error");
            }
            if (!response.sent) {
                response.status(500).send("Internal server error");
            }
        }
        http::free_response(response);
    } else {
        Response* response = http::new_response(client);
        response.status(404).send("Not found");
        http::free_response(response);
    }
}

fn void Router.send_bad_request(&self, TcpSocket* client, Request* request) {
    Response* response = http::new_response(client);
    response.status(400).send("Bad request");
    http::free_response(response);
}