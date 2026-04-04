const std = @import("std");
const http = std.http;

pub const WsClient = struct {
    ws: http.Server.WebSocket,
    authenticated: bool = false,

    pub fn send(self: *WsClient, data: []const u8) void {
        self.ws.writeMessage(data, .text) catch {};
    }

    pub fn readMessage(self: *WsClient) !http.Server.WebSocket.SmallMessage {
        return self.ws.readSmallMessage();
    }
};

pub const WsBroadcaster = struct {
    clients: std.ArrayList(*WsClient),
    mutex: std.Thread.Mutex = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) WsBroadcaster {
        return .{
            .clients = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WsBroadcaster) void {
        self.clients.deinit(self.allocator);
    }

    pub fn addClient(self: *WsBroadcaster, client: *WsClient) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.clients.append(self.allocator, client);
    }

    pub fn removeClient(self: *WsBroadcaster, client: *WsClient) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.clients.items, 0..) |c, i| {
            if (c == client) {
                _ = self.clients.swapRemove(i);
                return;
            }
        }
    }

    pub fn broadcast(self: *WsBroadcaster, data: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.clients.items) |client| {
            if (client.authenticated) {
                client.send(data);
            }
        }
    }

    pub fn broadcastToAll(self: *WsBroadcaster, data: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.clients.items) |client| {
            client.send(data);
        }
    }
};
