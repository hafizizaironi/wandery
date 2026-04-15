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
                .font(.system(size: 34))
                .foregroundStyle(AppTheme.cafeAccent, Color.white)
                .shadow(radius: 6)
                .offset(y: -17)

            // Bottom panel
            VStack {
                Spacer()
                VStack(spacing: 12) {
                    Text(String(format: "📍 %.5f, %.5f", centerCoord.latitude, centerCoord.longitude))
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.cream.opacity(0.6))

                    Button {
                        onPick(centerCoord)
                        dismiss()
                    } label: {
                        Text("Confirm Location")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(AppTheme.cream)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(AppTheme.cafeAccent)
                            .cornerRadius(14)
                    }
                }
                .padding(20)
                .background(.ultraThinMaterial)
            }
        }
        .navigationTitle("Pick Location")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}
