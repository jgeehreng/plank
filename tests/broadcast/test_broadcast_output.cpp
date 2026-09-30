#include "broadcast_output.h"

#include <fstream>
#include <iostream>
#include <string>

namespace {
  int failures = 0;

  void expect(bool condition, const char *message) {
    if (condition) return;
    std::cerr << message << '\n';
    ++failures;
  }
}  // namespace

int main() {
  using plank::broadcast::build;
  using plank::broadcast::configured;
  using plank::broadcast::request_t;

  request_t request;
  request.enabled = true;
  request.uv_path = "uv";
  request.ndi_name = "FLAME (Host)";
  request.codec = "libavcodec:encoder=prores";
  request.peer_ipv4 = "10.0.0.8";
  request.announced_ipv4 = "10.0.0.8";
  request.video_port = 5004;

  const auto command = build(request);
  expect(command.refusal.empty(), "pinned source should build");
  expect(command.argv.size() == 12, "sender argv length");
  expect(command.argv.size() > 2 && command.argv[2] == "ndi:name=FLAME (Host)", "pinned NDI name");
  expect(command.argv.size() > 8 && command.argv[8] == "libavcodec:encoder=prores", "admin codec");
  expect(!command.argv.empty() && command.argv.back() == "10.0.0.8", "client address is the destination");

  request.ndi_name = "";
  expect(build(request).argv.empty(), "empty NDI name is refused");
  request.ndi_name = "ndi";
  expect(build(request).argv.empty(), "bare ndi capture is refused");
  request.ndi_name = "OTHER (Host)";
  const auto other = build(request);
  expect(other.argv.size() > 2 && other.argv[2] == "ndi:name=OTHER (Host)", "a second name is not rewritten to the first");
  expect(other.argv.size() > 2 && other.argv[2].find("FLAME") == std::string::npos, "unpinned name is not selected");

  request.ndi_name = "FLAME (Host)";
  request.announced_ipv4 = "10.9.9.9";
  expect(build(request).argv.empty(), "address must be the connected client");
  request.announced_ipv4 = "10.0.0.8";
  request.enabled = false;
  expect(build(request).argv.empty(), "switch defaults the sender off");
  expect(!configured(false, "FLAME (Host)", "prores", "uv"), "disabled host is not inventory");
  expect(configured(true, "FLAME (Host)", "libavcodec:encoder=prores", "uv"), "complete host is inventory");
  expect(plank::broadcast::ipv4_text(0x0a000008u) == "10.0.0.8", "ipv4 text");

  std::ifstream admission("apps/host/linux/src/auth/plank_admission.h");
  std::string contents((std::istreambuf_iterator<char>(admission)), std::istreambuf_iterator<char>());
  expect(admission.good() && contents.find("BroadcastSource") == std::string::npos, "admission has no broadcast field");
  expect(contents.find("ndi_name") == std::string::npos, "admission has no NDI field");
  return failures == 0 ? 0 : 1;
}
