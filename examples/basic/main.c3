module main;
import framework;
import http;

fn void! handle_home(Request* req, Response* res) {
    res.status(200).send("<h1>Hello from home!</h1>");
}

fn void! handle_devices_no_id(Request* req, Response* res) {
    res.status(200).send("<h1>Hello from devices!</h1>");
}

fn void! handle_devices_with_id(Request* req, Response* res) {
    String id = req.get_param("id");
    if (id == "") {
        res.status(400).send("id path param is missing");
        return;
    }

    String abc = req.get_query_param("abc");
    if (abc == "") {
        res.status(400).send("abc query param is missing");
        return;
    }

    res.headers.set("content-type", "application/json");
    res.send("<h1>Hello from devices with id!</h1>");
}

fn void main() {
    Framework* app = framework::new_framework();

    app.post("/", &handle_home);

    RouteGroup* devices = app.new_route_group("/devices");

    devices.get("/", &handle_devices_no_id);
    devices.get("/{id}", &handle_devices_with_id);

    app.run();
}