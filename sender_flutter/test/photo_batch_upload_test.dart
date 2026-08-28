import 'package:flutter_test/flutter_test.dart';
import 'package:lan_media_cast_sender/app_controller.dart';
import 'package:lan_media_cast_sender/protocol/protocol.dart';

void main() {
  test(
    'continues after item failure and removes all failures in one revision',
    () async {
      final List<String> uploadOrder = <String>[];
      final List<List<String>> updates = <List<String>>[];
      int revision = 1;

      await expectLater(
        uploadPhotoBatchItems<String>(
          items: <String>['photo-1', 'photo-2', 'photo-3'],
          isComplete: (_) => false,
          uploadItem: (String item) async {
            uploadOrder.add(item);
            if (item == 'photo-2') throw StateError('digest mismatch');
          },
          canContinue: () => true,
          describeError: (Object error) => error.toString(),
          removeFailedItems: (List<String> failedItems) async {
            revision += 1;
            updates.add(List<String>.of(failedItems));
          },
        ),
        throwsA(isA<StateError>()),
      );

      expect(uploadOrder, <String>['photo-1', 'photo-2', 'photo-3']);
      expect(updates, <List<String>>[
        <String>['photo-2'],
      ]);
      expect(revision, 2);
    },
  );

  test('connection loss aborts without removing pending items', () async {
    int updateCount = 0;
    await expectLater(
      uploadPhotoBatchItems<String>(
        items: <String>['photo-1'],
        isComplete: (_) => false,
        uploadItem: (_) async => throw StateError('disconnected'),
        canContinue: () => false,
        describeError: (Object error) => error.toString(),
        removeFailedItems: (_) async => updateCount += 1,
      ),
      throwsA(isA<StateError>()),
    );
    expect(updateCount, 0);
  });

  test('final chunk ack is not success until item completion arrives', () {
    const String transferId = '11111111-1111-4111-8111-111111111111';
    ProtocolEnvelope event(String type, Map<String, dynamic> payload) =>
        ProtocolEnvelope(
          version: 1,
          type: type,
          id: null,
          replyTo: null,
          sessionId: null,
          commandSeq: null,
          timestamp: 1,
          payload: <String, dynamic>{'transferId': transferId, ...payload},
        );

    expect(
      isPhotoWindowResult(
        event('photo.chunk.ack', <String, dynamic>{'nextChunkIndex': 4}),
        transferId: transferId,
        windowEnd: 4,
        finalWindow: true,
      ),
      isFalse,
    );
    expect(
      isPhotoWindowResult(
        event('photo.item.complete', <String, dynamic>{}),
        transferId: transferId,
        windowEnd: 4,
        finalWindow: true,
      ),
      isTrue,
    );
    expect(
      isPhotoWindowResult(
        event('photo.item.failed', <String, dynamic>{}),
        transferId: transferId,
        windowEnd: 4,
        finalWindow: true,
      ),
      isTrue,
    );
    expect(
      isPhotoWindowResult(
        event('protocol.error', <String, dynamic>{
          'code': 'internal_error',
          'reason': 'internal_error',
        }),
        transferId: transferId,
        windowEnd: 4,
        finalWindow: true,
      ),
      isTrue,
    );
  });

  test(
    'batch removal commits revision only after remote acknowledgement',
    () async {
      final List<String> order = <String>[];
      int localRevision = 1;
      final int committedRevision = await commitPhotoBatchRemoval<String>(
        currentRevision: localRevision,
        failedItems: <String>['photo-2', 'photo-3'],
        itemId: (String item) => item,
        sendUpdate: (int revision, List<String> removedIds) async {
          order.add('remote:$revision:${removedIds.join(',')}');
          expect(localRevision, 1);
        },
        commitLocal: (int revision, List<String> failedItems) async {
          order.add('local:$revision:${failedItems.join(',')}');
          localRevision = revision;
        },
      );

      expect(committedRevision, 2);
      expect(localRevision, 2);
      expect(order, <String>[
        'remote:2:photo-2,photo-3',
        'local:2:photo-2,photo-3',
      ]);
    },
  );

  test('rejected batch update does not commit local revision', () async {
    int localRevision = 1;
    await expectLater(
      commitPhotoBatchRemoval<String>(
        currentRevision: localRevision,
        failedItems: <String>['photo-2'],
        itemId: (String item) => item,
        sendUpdate: (_, _) async => throw StateError('revision conflict'),
        commitLocal: (int revision, _) async => localRevision = revision,
      ),
      throwsA(isA<StateError>()),
    );
    expect(localRevision, 1);
  });

  test('batch update failure retains original item failure context', () async {
    await expectLater(
      uploadPhotoBatchItems<String>(
        items: <String>['photo-2'],
        isComplete: (_) => false,
        uploadItem: (_) async => throw StateError('digest mismatch'),
        canContinue: () => true,
        describeError: (_) => '照片校验失败',
        removeFailedItems: (_) async => throw StateError('update timeout'),
      ),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message.toString(),
          'message',
          allOf(contains('照片校验失败'), contains('同步失败项失败')),
        ),
      ),
    );
  });
}
