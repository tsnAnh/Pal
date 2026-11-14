"""A photo turn the gateway pre-analyzed for a text-only model names its photo only inside the vision note.

Failure case: the library never indexes that photo, so ``library.asset`` refuses it and the chat shows a
broken image after reopen.
"""
from hermes_state_library_extract import KIND_MEDIA, extract_message

PATH = "/srv/home/cache/documents/native-inputs/ab/upload_x1.jpg"
NOTE = ("[The user sent an image~ Here's what I can see:\nA field of pink flowers.]\n"
        f"[If you need a closer look, use vision_analyze with image_url: {PATH} ~]")


def test_the_photo_named_by_a_vision_note_is_indexed_as_media():
    found = extract_message("user", f"{NOTE}\n\nwhat flowers?", None, None)
    assert [(o.kind, o.locator) for o in found] == [(KIND_MEDIA, PATH)]


def test_a_failed_analysis_note_still_indexes_its_photo():
    text = f"[The user sent an image but I couldn't quite see it this time (>_<) You can try looking at it yourself with vision_analyze using image_url: {PATH}]"
    assert [o.locator for o in extract_message("user", text, None, None)] == [PATH]
