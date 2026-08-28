package com.iflytek.lanmediacast.receiver

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.BitmapFactory
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.GridLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import androidx.core.content.ContextCompat
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import androidx.media3.common.util.UnstableApi
import com.iflytek.lanmediacast.receiver.core.PairingRequest
import com.iflytek.lanmediacast.receiver.core.PhotoSlotUiState
import com.iflytek.lanmediacast.receiver.core.ReceiverRuntime
import com.iflytek.lanmediacast.receiver.core.ReceiverStandbyMode
import com.iflytek.lanmediacast.receiver.core.ReceiverUiState
import com.iflytek.lanmediacast.receiver.core.receiverStandbyMode
import com.iflytek.lanmediacast.receiver.service.CastServerService
import java.util.concurrent.Executors

@androidx.annotation.OptIn(markerClass = [UnstableApi::class])
class MainActivity : Activity() {
    private lateinit var playerView: PlayerView
    private lateinit var waitingPanel: FrameLayout
    private lateinit var photoContainer: FrameLayout
    private lateinit var deviceTitle: TextView
    private lateinit var connectionDetails: TextView
    private lateinit var connectionSubtitle: TextView
    private lateinit var connectionStatus: TextView
    private lateinit var endpointDetails: TextView
    private lateinit var banner: TextView
    private lateinit var pairingPanel: LinearLayout
    private lateinit var pairingTitle: TextView
    private lateinit var pairingCode: TextView
    private var currentPairing: PairingRequest? = null
    private var lastPhotoSlots: List<PhotoSlotUiState> = emptyList()
    private var zoomedPhotoId: String? = null
    private val imageExecutor = Executors.newSingleThreadExecutor()
    private val stateListener: (ReceiverUiState) -> Unit = { state -> runOnUiThread { render(state) } }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_SHOW_WALLPAPER,
        )
        window.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        enterImmersiveMode()
        ContextCompat.startForegroundService(this, Intent(this, CastServerService::class.java))
        setContentView(createContentView())
        ReceiverRuntime.addListener(stateListener)
    }

    override fun onDestroy() {
        ReceiverRuntime.removeListener(stateListener)
        playerView.player = null
        imageExecutor.shutdownNow()
        super.onDestroy()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) enterImmersiveMode()
    }

    private fun enterImmersiveMode() {
        @Suppress("DEPRECATION")
        window.decorView.systemUiVisibility =
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                View.SYSTEM_UI_FLAG_FULLSCREEN or
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE
    }

    private fun createContentView(): View {
        val density = resources.displayMetrics.density
        val root = FrameLayout(this).apply { setBackgroundColor(Color.TRANSPARENT) }
        playerView = PlayerView(this).apply {
            useController = false
            // Keep burned-in subtitles and edge content visible on screens with a different aspect ratio.
            resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
            setBackgroundColor(Color.BLACK)
            setShutterBackgroundColor(Color.BLACK)
            player = ReceiverRuntime.player
            visibility = View.GONE
        }
        root.addView(
            playerView,
            FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT),
        )

        photoContainer = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            visibility = View.GONE
        }
        root.addView(
            photoContainer,
            FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT),
        )

        waitingPanel = FrameLayout(this).apply {
            setBackgroundColor(Color.argb(188, 7, 12, 15))
        }
        val topBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding((24 * density).toInt(), 0, (24 * density).toInt(), 0)
            setBackgroundColor(Color.argb(158, 10, 16, 20))
            deviceTitle = TextView(context).apply {
                textSize = 16f
                setTextColor(Color.WHITE)
                setTypeface(typeface, Typeface.BOLD)
                maxLines = 1
                ellipsize = TextUtils.TruncateAt.END
            }
            endpointDetails = TextView(context).apply {
                textSize = 14f
                setTextColor(Color.rgb(178, 196, 201))
                gravity = Gravity.END
                maxLines = 1
                ellipsize = TextUtils.TruncateAt.END
            }
            addView(
                deviceTitle,
                LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
                    marginEnd = (24 * density).toInt()
                },
            )
            addView(
                endpointDetails,
                LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f),
            )
        }
        waitingPanel.addView(
            topBar,
            FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, (58 * density).toInt(), Gravity.TOP),
        )

        val standbyContent = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding((32 * density).toInt(), 0, (32 * density).toInt(), 0)
        }
        val brandSize = (104 * density).toInt()
        val brandFrame = FrameLayout(this).apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.argb(170, 13, 28, 34))
                setStroke((1.5f * density).toInt().coerceAtLeast(1), Color.rgb(72, 178, 205))
            }
            addView(
                ImageView(context).apply {
                    contentDescription = getString(R.string.app_name)
                    setImageResource(R.mipmap.ic_launcher)
                    scaleType = ImageView.ScaleType.CENTER_INSIDE
                    setPadding(
                        (14 * density).toInt(),
                        (14 * density).toInt(),
                        (14 * density).toInt(),
                        (14 * density).toInt(),
                    )
                },
                FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    FrameLayout.LayoutParams.MATCH_PARENT,
                ),
            )
        }
        standbyContent.addView(
            brandFrame,
            LinearLayout.LayoutParams(brandSize, brandSize).apply {
                bottomMargin = (20 * density).toInt()
            },
        )
        standbyContent.addView(
            TextView(this).apply {
                text = getString(R.string.app_name)
                textSize = 13f
                setTextColor(Color.rgb(142, 181, 191))
                gravity = Gravity.CENTER
            },
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply {
                bottomMargin = (8 * density).toInt()
            },
        )
        connectionDetails = TextView(this).apply {
            textSize = 32f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            setTypeface(typeface, Typeface.BOLD)
        }
        standbyContent.addView(connectionDetails)
        connectionSubtitle = TextView(this).apply {
            textSize = 18f
            setTextColor(Color.rgb(218, 228, 231))
            gravity = Gravity.CENTER
            maxLines = 2
            ellipsize = TextUtils.TruncateAt.END
            setPadding(0, (12 * density).toInt(), 0, 0)
        }
        standbyContent.addView(connectionSubtitle)
        connectionStatus = TextView(this).apply {
            textSize = 14f
            gravity = Gravity.CENTER
            setPadding(
                (18 * density).toInt(),
                (8 * density).toInt(),
                (18 * density).toInt(),
                (8 * density).toInt(),
            )
        }
        standbyContent.addView(
            connectionStatus,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply {
                topMargin = (22 * density).toInt()
            },
        )
        waitingPanel.addView(
            standbyContent,
            FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER).apply {
                topMargin = (30 * density).toInt()
            },
        )
        root.addView(
            waitingPanel,
            FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT),
        )

        banner = TextView(this).apply {
            gravity = Gravity.CENTER_VERTICAL
            setPadding((16 * density).toInt(), 0, (16 * density).toInt(), 0)
            setTextColor(Color.WHITE)
            textSize = 15f
            visibility = View.GONE
        }
        root.addView(
            banner,
            FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, (40 * density).toInt(), Gravity.TOP),
        )

        pairingPanel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding((28 * density).toInt(), (22 * density).toInt(), (28 * density).toInt(), (22 * density).toInt())
            setBackgroundColor(Color.argb(242, 28, 31, 34))
            visibility = View.GONE
            pairingTitle = TextView(context).apply {
                textSize = 20f
                setTextColor(Color.WHITE)
                gravity = Gravity.CENTER
            }
            pairingCode = TextView(context).apply {
                textSize = 38f
                setTextColor(Color.rgb(109, 213, 170))
                gravity = Gravity.CENTER
                setPadding(0, (10 * density).toInt(), 0, 0)
            }
            addView(pairingTitle)
            addView(pairingCode)
        }
        val width = (460 * density).toInt()
        root.addView(
            pairingPanel,
            FrameLayout.LayoutParams(width, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER),
        )
        return root
    }

    private fun render(state: ReceiverUiState) {
        if (playerView.player !== ReceiverRuntime.player) playerView.player = ReceiverRuntime.player
        val hasLoadedMedia = (ReceiverRuntime.player?.mediaItemCount ?: 0) > 0
        val standbyMode = receiverStandbyMode(state, hasLoadedMedia)
        val showStandby = standbyMode != ReceiverStandbyMode.HIDDEN
        renderStandby(state, standbyMode)
        playerView.visibility = if (state.mode == "media" && !showStandby) View.VISIBLE else View.GONE
        photoContainer.visibility = if (state.mode == "photo" && state.photoSlots.isNotEmpty()) View.VISIBLE else View.GONE
        waitingPanel.visibility = if (showStandby) View.VISIBLE else View.GONE
        if (state.photoSlots != lastPhotoSlots) {
            lastPhotoSlots = state.photoSlots
            val focusedId = zoomedPhotoId
            if (focusedId != null && state.photoSlots.none { it.photoId == focusedId && it.path != null }) {
                zoomedPhotoId = null
            }
            renderPhotos()
        }
        banner.text = state.banner
        banner.visibility = if (state.banner == null) View.GONE else View.VISIBLE
        banner.setBackgroundColor(
            if (state.bannerIsError) Color.argb(220, 155, 48, 48) else Color.argb(210, 176, 104, 24),
        )
        currentPairing = state.pairingRequest
        pairingPanel.visibility = if (currentPairing == null) View.GONE else View.VISIBLE
        currentPairing?.let {
            pairingTitle.text = "在 ${it.senderName} 上输入连接码"
            pairingCode.text = it.code
        }
    }

    private fun renderStandby(state: ReceiverUiState, mode: ReceiverStandbyMode) {
        val density = resources.displayMetrics.density
        deviceTitle.text = "${getString(R.string.app_name)}  ·  ${state.deviceName}"
        endpointDetails.text = "${state.address}:${state.controlPort}"
        when (mode) {
            ReceiverStandbyMode.WAITING_FOR_CONNECTION -> {
                connectionDetails.text = "等待设备连接"
                connectionSubtitle.text = "接收端已就绪，正在等待发送端"
                connectionStatus.text = "局域网服务已就绪"
                connectionStatus.setTextColor(Color.rgb(125, 215, 232))
                connectionStatus.background = GradientDrawable().apply {
                    cornerRadius = 18 * density
                    setColor(Color.argb(210, 15, 49, 59))
                    setStroke(density.toInt().coerceAtLeast(1), Color.rgb(51, 121, 138))
                }
            }
            ReceiverStandbyMode.READY_FOR_MEDIA -> {
                connectionDetails.text = "等待播放"
                connectionSubtitle.text = "已连接发送端：${state.connectedSender}"
                connectionStatus.text = "可以开始播放"
                connectionStatus.setTextColor(Color.rgb(143, 226, 181))
                connectionStatus.background = GradientDrawable().apply {
                    cornerRadius = 18 * density
                    setColor(Color.argb(215, 21, 57, 43))
                    setStroke(density.toInt().coerceAtLeast(1), Color.rgb(58, 132, 94))
                }
            }
            ReceiverStandbyMode.HIDDEN -> Unit
        }
    }

    private fun renderPhotos() {
        photoContainer.removeAllViews()
        val slots = lastPhotoSlots
        if (slots.isEmpty()) return
        val focused = zoomedPhotoId?.let { focusedId -> slots.firstOrNull { it.photoId == focusedId } }
        if (focused != null || slots.size == 1) {
            val slot = focused ?: slots.first()
            val view = createPhotoSlotView(slot, 2_560)
            view.setOnClickListener {
                if (slots.size > 1 && slot.path != null) {
                    zoomedPhotoId = null
                    renderPhotos()
                }
            }
            photoContainer.addView(
                view,
                FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT),
            )
            return
        }
        val density = resources.displayMetrics.density
        val grid = GridLayout(this).apply {
            columnCount = 3
            rowCount = (slots.size + 2) / 3
            setPadding((6 * density).toInt(), (6 * density).toInt(), (6 * density).toInt(), (6 * density).toInt())
        }
        slots.forEachIndexed { index, slot ->
            val view = createPhotoSlotView(slot, 1_280)
            if (slot.path != null) {
                view.setOnClickListener {
                    zoomedPhotoId = slot.photoId
                    renderPhotos()
                }
            }
            grid.addView(
                view,
                GridLayout.LayoutParams(
                    GridLayout.spec(index / 3, 1f),
                    GridLayout.spec(index % 3, 1f),
                ).apply {
                    width = 0
                    height = 0
                    setMargins((3 * density).toInt(), (3 * density).toInt(), (3 * density).toInt(), (3 * density).toInt())
                },
            )
        }
        photoContainer.addView(
            grid,
            FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT),
        )
    }

    private fun createPhotoView(path: String) = ImageView(this).apply {
        contentDescription = path.substringAfterLast('/')
        scaleType = ImageView.ScaleType.FIT_CENTER
        setBackgroundColor(Color.BLACK)
    }

    private fun createPhotoSlotView(slot: PhotoSlotUiState, maxDimension: Int): View {
        val path = slot.path
        if (path == null) {
            return FrameLayout(this).apply {
                setBackgroundColor(Color.rgb(18, 22, 24))
                addView(
                    ProgressBar(context),
                    FrameLayout.LayoutParams(
                        FrameLayout.LayoutParams.WRAP_CONTENT,
                        FrameLayout.LayoutParams.WRAP_CONTENT,
                        Gravity.CENTER,
                    ),
                )
            }
        }
        return createPhotoView(path).also { image -> loadSampledBitmap(image, path, maxDimension) }
    }

    private fun loadSampledBitmap(view: ImageView, path: String, maxDimension: Int) {
        imageExecutor.execute {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            var sample = 1
            while (bounds.outWidth / sample > maxDimension || bounds.outHeight / sample > maxDimension) sample *= 2
            val bitmap = BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample })
            runOnUiThread {
                if (!isDestroyed && view.parent != null) view.setImageBitmap(bitmap) else bitmap?.recycle()
            }
        }
    }
}
