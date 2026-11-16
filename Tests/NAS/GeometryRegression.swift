import Foundation

@main struct GeometryRegression {
  static func main() {
    for value in ["", "1440", "x900", "100%", "0%", "50%+20%-10%", "+0+0", "1280x720-10+20"] {
      precondition(GeometryDef.isValidPreference(value), "Rejected valid geometry: \(value)")
      precondition(GeometryDef.safeOption(value) == value)
    }
    for value in ["1440%", "101%", "x101%", "50%+101%+0", "50%-0-101%", "foo", "1.5%", "100%\n", "9999999999999999999999999999"] {
      precondition(!GeometryDef.isValidPreference(value), "Accepted invalid geometry: \(value)")
      precondition(GeometryDef.safeOption(value).isEmpty)
    }
    print("PASS: geometry percent bounds, valid point dimensions, offsets, malformed values and legacy preference fallback")
  }
}
