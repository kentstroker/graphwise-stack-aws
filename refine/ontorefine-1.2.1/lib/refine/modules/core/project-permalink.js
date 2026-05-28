/**
 * Attaches 'onclick' event on the project permalink icon. It will handles the copying of the
 * project link to the clipboard, if it is enabled. Otherwise it will provide to the user an
 * option to copy the link manually via alert notification.
 */
document.getElementById('project-permalink-button').onclick = async function (event) {
    event.preventDefault();

    var link = document.getElementById('project-permalink-button').href;

    if (!navigator.clipboard) {
        prompt('The clipboard is disabled!\nAs alternative you can copy the link manually.\n\nProject permalink:', link);
        return false;
    }

    navigator.clipboard.writeText(link).then(() => {
        alert('The project link was copied to the clipboard!');
    }, () => {
        prompt('The clipboard is disabled!\nAs alternative you can copy the link manually.\n\nProject permalink:', link);
    });
    return false;
}
