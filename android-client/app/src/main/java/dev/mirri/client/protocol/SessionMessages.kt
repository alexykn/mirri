package dev.mirri.client.protocol

/** Domain values are created only after WireCodec has checked the complete record. */
enum class MessageType(
    val id: Int,
) {
    CLIENT_HELLO(1),
    SESSION_CONFIG(2),
    CLIENT_READY(3),
    VIDEO_HELLO(4),
    CODEC_CONFIG(5),
    VIDEO_FRAME(6),
    START_STREAM(7),
    STOP_SESSION(8),
    INPUT_BATCH(9),
    SCROLL(10),
    ZOOM(11),
    CONTEXT(12),
    SHORTCUT(13),
    AUXILIARY(14),
    PING(15),
    PONG(16),
    CLIENT_METRICS(17),
    ERROR(18),
    DECODER_FAILURE(19),
    REQUEST_KEYFRAME(20),
    REJECTED(21),
    STOP_ACK(22),
    RTC_CAPABILITIES(23),
    RTC_PREPARE(24),
    RTC_PREPARED(25),
    RTC_OFFER(26),
    RTC_ANSWER(27),
    RTC_ICE_CANDIDATE(28),
    RTC_ICE_END(29),
    RTC_MEDIA_READY(30),
    RTC_START(31),
}

enum class VideoCodecId(
    val wire: Int,
    val minimumBitrate: Long,
) {
    AVC(1, 20_000_000),
    HEVC(2, 25_000_000),
    ;

    companion object {
        fun fromWire(id: Int): VideoCodecId = entries.firstOrNull { it.wire == id } ?: throw WireException("unknown hardware codec")
    }
}

data class PhysicalMode(
    val width: Long,
    val height: Long,
    val milliHz: Long,
    val identifier: Int,
) {
    val isExact: Boolean get() = width == 1600L && height == 2456L && (milliHz == 60000L || milliHz == 120000L)
}

data class CodecOffer(
    val codec: VideoCodecId,
    val profile: Int,
    val level: Int,
    val exact: Boolean,
    val lowLatency: Boolean,
    val hardware: Boolean,
)

data class InputCapabilities(
    val maxTouch: Int,
    val pen: Boolean,
    val pressure: Boolean,
    val tilt: Boolean,
    val hover: Boolean,
    val auxiliary: Boolean,
)

data class ClientDeviceHello(
    val epoch: UInt,
    val token: ByteArray,
    val name: String,
    val width: Int,
    val height: Int,
    val density: Int,
    val active: PhysicalMode,
    val modes: List<PhysicalMode>,
    val codecs: List<CodecOffer>,
    val input: InputCapabilities,
)

data class SessionConfiguration(
    val id: ByteArray,
    val epoch: UInt,
    val codec: VideoCodecId,
    val profile: Int,
    val level: Int,
    val bitrate: Long,
)

data class VideoConfiguration(
    val id: ByteArray,
    val epoch: UInt,
    val generation: Long,
    val codec: VideoCodecId,
    val parameterSets: List<ByteArray>,
)

enum class PointerTool(
    val wire: Int,
) {
    FINGER(1),
    PEN(2),
    ERASER(3),
}

enum class PointerPhase(
    val wire: Int,
) {
    HOVER_ENTER(1),
    HOVER_MOVE(2),
    HOVER_EXIT(3),
    DOWN(4),
    MOVE(5),
    UP(6),
    CANCEL(7),
}

enum class GesturePhase(
    val wire: Int,
) {
    BEGAN(1),
    CHANGED(2),
    ENDED(3),
    CANCELLED(4),
}

enum class ContextSource(
    val wire: Int,
) {
    LONG_PRESS(1),
    TWO_FINGER_TAP(2),
    PEN_BUTTON(3),
}

enum class ShortcutAction(
    val wire: Int,
) {
    MISSION_CONTROL(1),
    PREVIOUS_SPACE(2),
    NEXT_SPACE(3),
    SHOW_DESKTOP(4),
    CUSTOM(5),
}

enum class KeyPhase(
    val wire: Int,
) {
    DOWN(1),
    UP(2),
}

data class InputPoint(
    val x: Float,
    val y: Float,
)

data class PointerReading(
    val id: Int,
    val tool: PointerTool,
    val phase: PointerPhase,
    val point: InputPoint,
    val pressure: Float,
    val tilt: Float,
    val orientation: Float,
    val buttons: Int,
    val time: Long,
)

sealed interface InputEvent {
    data class Pointers(
        val samples: List<PointerReading>,
    ) : InputEvent

    data class Scroll(
        val phase: GesturePhase,
        val point: InputPoint,
        val x: Float,
        val y: Float,
        val time: Long,
    ) : InputEvent

    data class Zoom(
        val phase: GesturePhase,
        val point: InputPoint,
        val scale: Float,
        val time: Long,
    ) : InputEvent

    data class Context(
        val point: InputPoint,
        val source: ContextSource,
        val time: Long,
    ) : InputEvent

    data class Shortcut(
        val action: ShortcutAction,
        val time: Long,
    ) : InputEvent

    data class Auxiliary(
        val code: Int,
        val scan: Int,
        val phase: KeyPhase,
        val time: Long,
    ) : InputEvent
}

sealed interface HostEvent {
    data class Configure(
        val config: SessionConfiguration,
    ) : HostEvent

    data class Start(
        val generation: UInt,
    ) : HostEvent

    data class Ping(
        val sequence: ULong,
        val sent: ULong,
    ) : HostEvent

    data object Stop : HostEvent

    data object Error : HostEvent
}

/** All positional casts for host control traffic live here, never in session owners. */
object SessionMessages {
    private fun number(v: Value) = (v as? Value.Number)?.value ?: throw WireException("invalid session record")

    private fun values(v: Value) = (v as? Value.Object)?.value ?: throw WireException("invalid session record")

    fun clientHelloFields(hello: ClientDeviceHello): List<Value> {
        fun n(value: Long) = Value.Number(value.toULong())

        fun size(
            width: Long,
            height: Long,
        ) = Value.Object(listOf(n(width), n(height)))

        fun mode(value: PhysicalMode) =
            Value.Object(
                listOf(
                    size(value.width, value.height),
                    n(value.milliHz),
                    Value.Signed(value.identifier),
                ),
            )

        fun yes(value: Boolean) = n(if (value) 1 else 0)
        return listOf(
            n(hello.epoch.toLong()),
            Value.Bytes(hello.token),
            Value.Text(hello.name),
            size(hello.width.toLong(), hello.height.toLong()),
            n(hello.density.toLong()),
            mode(hello.active),
            Value.Items(hello.modes.map(::mode)),
            Value.Items(
                hello.codecs.map { offer ->
                    Value.Object(
                        listOf(
                            n(offer.codec.wire.toLong()),
                            Value.Items(listOf(Value.Object(listOf(n(offer.profile.toLong()), n(offer.level.toLong()))))),
                            yes(offer.exact),
                            yes(offer.lowLatency),
                            yes(offer.hardware),
                        ),
                    )
                },
            ),
            Value.Object(
                listOf(
                    n(hello.input.maxTouch.toLong()),
                    yes(hello.input.pen),
                    yes(hello.input.pressure),
                    yes(hello.input.tilt),
                    yes(hello.input.hover),
                    yes(hello.input.auxiliary),
                ),
            ),
        )
    }

    fun fromVideoConfig(message: WireMessage): VideoConfiguration {
        if (message.type != MessageType.CODEC_CONFIG.id) throw WireException("expected codec config")
        val f = message.fields
        val sets = (f[7] as Value.Items).value.map { (it as Value.Bytes).value }
        return VideoConfiguration(
            (f[0] as Value.Bytes).value,
            number(f[1]).toUInt(),
            number(f[2]).toLong(),
            VideoCodecId.fromWire(number(f[3]).toInt()),
            sets,
        )
    }

    fun fromHost(message: WireMessage): HostEvent {
        val f = message.fields
        return when (message.type) {
            MessageType.SESSION_CONFIG.id -> {
                val codec = VideoCodecId.fromWire(number(f[2]).toInt())
                val dimensions = values(f[5])
                val bitrate = number(f[7]).toLong()
                val exactCodec = number(f[3]).toInt() == codec.wire
                val exactSize = number(dimensions[0]) == 2456uL && number(dimensions[1]) == 1600uL
                val exactStream = number(f[6]) == 60000uL && bitrate in codec.minimumBitrate..80_000_000L
                val exactTransport = number(f[8]) == 1uL && number(f[9]) == 5560uL
                val exactInput = number(f[10]) == 1uL && number(f[11]) == 1uL
                val exactMedia = exactCodec && exactSize && exactStream
                if (!exactMedia || !exactTransport || !exactInput) {
                    throw WireException("exact session config mismatch")
                }
                HostEvent.Configure(
                    SessionConfiguration(
                        (f[0] as Value.Bytes).value,
                        number(f[1]).toUInt(),
                        codec,
                        number(f[3]).toInt(),
                        number(f[4]).toInt(),
                        bitrate,
                    ),
                )
            }
            MessageType.START_STREAM.id -> HostEvent.Start(number(f[2]).toUInt())
            MessageType.STOP_SESSION.id -> HostEvent.Stop
            MessageType.PING.id -> HostEvent.Ping(number(f[2]), number(f[3]))
            MessageType.ERROR.id -> HostEvent.Error
            else -> throw WireException("unexpected host control message")
        }
    }
}

/** Client outbound envelope and schema: no session owner constructs a Value tree. */
sealed interface ClientCommand {
    data class Input(
        val event: InputEvent,
        val batchSequence: ULong,
    ) : ClientCommand

    data class Ready(
        val mode: PhysicalMode,
        val decoderName: String,
    ) : ClientCommand

    data class Rejection(
        val reason: Int,
        val text: String,
    ) : ClientCommand

    data class Failure(
        val code: Int,
    ) : ClientCommand

    data class ProtocolFailure(
        val code: Int,
    ) : ClientCommand

    data class Keyframe(
        val generation: UInt,
    ) : ClientCommand

    data class Pong(
        val sequence: ULong,
        val sent: ULong,
        val received: Long,
        val replied: Long,
    ) : ClientCommand

    data class Metrics(
        val receiveFps: Float,
        val bits: Long,
        val inputFps: Float,
        val outputFps: Float,
        val mode: PhysicalMode,
        val depth: Int,
        val dropped: Long,
    ) : ClientCommand

    data object Acknowledged : ClientCommand

    fun fields(
        id: ByteArray,
        epoch: UInt,
    ): Pair<MessageType, List<Value>> {
        fun n(value: Long) = Value.Number(value.toULong())

        fun mode(value: PhysicalMode) =
            Value.Object(
                listOf(
                    Value.Object(listOf(n(value.width), n(value.height))),
                    n(value.milliHz),
                    Value.Signed(value.identifier),
                ),
            )

        fun point(value: InputPoint) = Value.Object(listOf(Value.Real(value.x), Value.Real(value.y)))

        fun reading(value: PointerReading) =
            Value.Object(
                listOf(
                    n(value.id.toLong()),
                    n(value.tool.wire.toLong()),
                    n(value.phase.wire.toLong()),
                    point(value.point),
                    Value.Real(value.pressure),
                    Value.Real(value.tilt),
                    Value.Real(value.orientation),
                    n(value.buttons.toLong()),
                    n(value.time),
                ),
            )
        val envelope = listOf(Value.Bytes(id), n(epoch.toLong()))
        val (type, payload) =
            when (this) {
                is Input ->
                    when (val value = event) {
                        is InputEvent.Pointers ->
                            MessageType.INPUT_BATCH to
                                listOf(Value.Number(batchSequence), Value.Items(value.samples.map(::reading)))
                        is InputEvent.Scroll ->
                            MessageType.SCROLL to
                                listOf(
                                    n(value.phase.wire.toLong()),
                                    point(value.point),
                                    Value.Real(value.x),
                                    Value.Real(value.y),
                                    n(value.time),
                                )
                        is InputEvent.Zoom ->
                            MessageType.ZOOM to
                                listOf(
                                    n(value.phase.wire.toLong()),
                                    point(value.point),
                                    Value.Real(value.scale),
                                    n(value.time),
                                )
                        is InputEvent.Context ->
                            MessageType.CONTEXT to
                                listOf(
                                    point(value.point),
                                    n(value.source.wire.toLong()),
                                    n(value.time),
                                )
                        is InputEvent.Shortcut -> MessageType.SHORTCUT to listOf(n(value.action.wire.toLong()), n(value.time))
                        is InputEvent.Auxiliary ->
                            MessageType.AUXILIARY to
                                listOf(
                                    n(value.code.toLong()),
                                    n(value.scan.toLong()),
                                    n(value.phase.wire.toLong()),
                                    n(value.time),
                                )
                    }
                is Ready ->
                    MessageType.CLIENT_READY to
                        listOf(mode(mode), Value.Text(decoderName), Value.Object(listOf(n(2456), n(1600))))
                is Rejection -> MessageType.REJECTED to listOf(n(reason.toLong()), Value.Text(text))
                is Failure -> MessageType.DECODER_FAILURE to listOf(n(code.toLong()))
                is ProtocolFailure -> MessageType.ERROR to listOf(n(code.toLong()), Value.Text("RTC attempt rejected"), n(1))
                is Keyframe -> MessageType.REQUEST_KEYFRAME to listOf(n(generation.toLong()))
                is Pong -> MessageType.PONG to listOf(n(sequence.toLong()), n(sent.toLong()), n(received), n(replied))
                is Metrics ->
                    MessageType.CLIENT_METRICS to
                        listOf(
                            Value.Real(receiveFps),
                            n(bits),
                            Value.Real(inputFps),
                            Value.Real(outputFps),
                            mode(mode),
                            n(depth.toLong()),
                            n(dropped),
                        )
                Acknowledged -> MessageType.STOP_ACK to emptyList()
            }
        return type to (envelope + payload)
    }
}
