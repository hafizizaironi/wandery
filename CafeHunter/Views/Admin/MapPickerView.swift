import SwiftUI
import MapKit

/// Full-screen map picker — pan the crosshair over the desired location, then tap Confirm.
struct MapPickerView: View {
    let onPick: (CLLocationCoordinate2D) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var position: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 3.3370, longitude: 101.5742),
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        )
    )
    @State private var centerCoord = CLLocationCoordinate2D(latitude: 3.3370, longitude: 101.5742)

    var body: some View {
        ZStack {
            // Map — tracks camera centre
            Map(position: $position)
                .onMapCameraChange { ctx in
                    centerCoord = ctx.region.center
                }
                .ignoresSafeArea()

            // Crosshair
            Image(systemName: "mappin.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(AppTheme.cafeAccent, Color.white)
                .shadow(radius: 6)
                .offset(y: -17)
                .accessibilityHidden(true)

            // Top-left close button
            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.footnote).bold()
                            .foregroundStyle(AppTheme.cream)
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                            .overlay {
                                Circle().stroke(AppTheme.glassStroke, lineWidth: 1)
                            }
                    }
                    .padding(.leading, 16)
                    .padding(.top, 56)
                    .accessibilityLabel("Close map picker")

                    Spacer()
                }
                Spacer()
            }

            // Bottom panel
            VStack {
                Spacer()
                VStack(spacing: 12) {
                    Text("📍 \(centerCoord.latitude, format: .number.precision(.fractionLength(5))), \(centerCoord.longitude, format: .number.precision(.fractionLength(5)))")
                        .font(.caption)
                        .foregroundStyle(AppTheme.cream.opacity(0.6))

                    Button {
                        onPick(centerCoord)
                        dismiss()
                    } label: {
                        Text("Confirm Location")
                            .font(.subheadline).bold()
                            .foregroundStyle(AppTheme.textOnAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(AppTheme.cafeAccent)
                            .clipShape(.rect(cornerRadius: 14))
                    }
                }
                .padding(20)
                .background(.ultraThinMaterial)
            }
        }
    }
}
