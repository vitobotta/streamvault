# frozen_string_literal: true

module Media
  class ProcessManager
    SHUTDOWN_GRACE_SECONDS = 1

    def self.kill_group(pid)
      return if pid.nil?

      return waitpid(pid) unless signal_group(pid, "CONT")
      return waitpid(pid) unless signal_group(pid, "TERM")

      deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + SHUTDOWN_GRACE_SECONDS
      while group_alive?(pid) && ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) < deadline
        reap(pid)
        sleep 0.05
      end
      signal_group(pid, "KILL") if group_alive?(pid)
      waitpid(pid)
    end

    def self.signal_group(pid, signal)
      ::Process.kill(signal, -pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end
    private_class_method :signal_group

    def self.group_alive?(pid)
      ::Process.kill(0, -pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end
    private_class_method :group_alive?

    def self.reap(pid)
      ::Process.waitpid2(pid, ::Process::WNOHANG)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
    private_class_method :reap

    def self.waitpid(pid)
      ::Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
    private_class_method :waitpid
  end
end
