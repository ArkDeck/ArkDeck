using System.ComponentModel;
using System.Runtime.InteropServices;
using ArkDeck.ClientKit.Transport;
using Microsoft.Win32.SafeHandles;

namespace ArkDeck.ClientKit.Tests;

[TestClass]
public sealed class ProcessIdentityTests
{
    [TestMethod]
    public void RetainedNamespacePreventsAncestorRenamesUntilDisposed()
    {
        var root = Directory.CreateTempSubdirectory("arkdeck-image-lock-").FullName;
        var renamedRoot = root + "-renamed";
        var parent = Directory.CreateDirectory(Path.Combine(root, "parent")).FullName;
        var child = Directory.CreateDirectory(Path.Combine(parent, "child")).FullName;
        var path = Path.Combine(child, "image.exe");
        File.WriteAllText(path, "namespace locking fixture");
        try
        {
            var (held, image) = FileIdentity.LockImage(FileIdentity.Canonicalize(path));
            try
            {
                foreach (var ancestor in new[] { root, parent, child })
                {
                    Assert.ThrowsExactly<IOException>(() => Directory.Move(ancestor, ancestor + "-renamed"), ancestor);
                }
                Assert.ThrowsExactly<IOException>(() => File.WriteAllText(path, "replacement"));
            }
            finally
            {
                image.Dispose();
                held.ForEach(handle => handle.Dispose());
            }
            Directory.Move(root, renamedRoot);
            File.WriteAllText(Path.Combine(renamedRoot, "parent", "child", "image.exe"), "released");
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
            if (Directory.Exists(renamedRoot)) Directory.Delete(renamedRoot, recursive: true);
        }
    }

    [TestMethod]
    public void PeerImageAccessRetainsLocksAndRevertsBeforeReturningThem()
    {
        var root = Directory.CreateTempSubdirectory("arkdeck-peer-image-").FullName;
        var renamed = root + "-renamed";
        var path = Path.Combine(root, "image.exe");
        File.WriteAllText(path, "peer image fixture");
        using var process = OwnProcess();
        RequireNoThreadToken();
        try
        {
            List<SafeFileHandle> held;
            SafeFileHandle image;
            using (var access = PeerImageAccess.Enter(process))
            {
                RequireOwnThreadToken();
                (held, image) = FileIdentity.LockImage(FileIdentity.Canonicalize(path));
            }
            try
            {
                RequireNoThreadToken();
                Assert.ThrowsExactly<IOException>(() => Directory.Move(root, renamed));
                Assert.ThrowsExactly<IOException>(() => File.WriteAllText(path, "replacement"));
            }
            finally
            {
                image.Dispose();
                held.ForEach(handle => handle.Dispose());
            }
            Directory.Move(root, renamed);
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
            if (Directory.Exists(renamed)) Directory.Delete(renamed, recursive: true);
        }
    }

    [TestMethod]
    public void FailedImageOpenRevertsPeerAccessAndReleasesAncestors()
    {
        var root = Directory.CreateTempSubdirectory("arkdeck-peer-failed-").FullName;
        var renamed = root + "-renamed";
        using var process = OwnProcess();
        RequireNoThreadToken();
        try
        {
            Assert.ThrowsExactly<Win32Exception>(() =>
            {
                using var access = PeerImageAccess.Enter(process);
                RequireOwnThreadToken();
                FileIdentity.LockImage(Path.Combine(root, "missing.exe"));
            });
            RequireNoThreadToken();
            Directory.Move(root, renamed);
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
            if (Directory.Exists(renamed)) Directory.Delete(renamed, recursive: true);
        }
    }

    [TestMethod]
    public void ExistingThreadIdentityIsRefusedAndPreserved()
    {
        using var process = OwnProcess();
        RequireNoThreadToken();
        using (var access = PeerImageAccess.Enter(process))
        {
            RequireOwnThreadToken();
            var error = Assert.ThrowsExactly<UnauthorizedAccessException>(() =>
            {
                using var nested = PeerImageAccess.Enter(process);
            });
            StringAssert.Contains(error.Message, "cannot replace a thread identity");
            RequireOwnThreadToken();
        }
        RequireNoThreadToken();
        using (var access = PeerImageAccess.Enter(process)) RequireOwnThreadToken();
        RequireNoThreadToken();
    }

    [TestMethod]
    public void InvalidPeerProcessCannotLeaveAnImpersonationToken()
    {
        RequireNoThreadToken();
        using var invalid = new SafeProcessHandle(IntPtr.Zero, ownsHandle: false);
        Assert.ThrowsExactly<Win32Exception>(() =>
        {
            using var access = PeerImageAccess.Enter(invalid);
        });
        RequireNoThreadToken();
    }

    private static SafeProcessHandle OwnProcess()
    {
        var process = Native.OpenProcess(Native.PROCESS_QUERY_LIMITED_INFORMATION | Native.SYNCHRONIZE, false, (uint)Environment.ProcessId);
        Assert.IsFalse(process.IsInvalid);
        return process;
    }

    private static void RequireNoThreadToken()
    {
        var opened = Native.OpenThreadToken(Native.GetCurrentThread(), Native.TOKEN_QUERY, true, out var token);
        var error = Marshal.GetLastPInvokeError();
        using (token)
        {
            Assert.IsFalse(opened, "peer authority leaked outside the image-open scope");
            Assert.AreEqual(Native.ERROR_NO_TOKEN, error);
        }
    }

    private static void RequireOwnThreadToken()
    {
        Assert.IsTrue(Native.OpenThreadToken(Native.GetCurrentThread(), Native.TOKEN_QUERY, true, out var token));
        using (token)
        using (var current = ProcessToken.Open())
        {
            Assert.AreEqual(ProcessToken.User(current), ProcessToken.User(token));
            Assert.AreEqual(ProcessToken.Elevated(current), ProcessToken.Elevated(token));
        }
    }
}
