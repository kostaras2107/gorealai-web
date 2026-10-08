package gr.gorealai.app

import android.os.Bundle
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Edge-to-edge is enforced on Android 15+ (API 35); this is the
        // non-deprecated AndroidX way to opt in, replacing the old
        // Window.setStatusBarColor()/setNavigationBarColor() approach.
        WindowCompat.setDecorFitsSystemWindows(window, false)
    }
}
